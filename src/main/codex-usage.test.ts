import { mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import {
  describeCodexWindow,
  findCodexRollouts,
  parseRolloutLine,
  readCodexUsage,
  readLastRateLimits,
} from './codex-usage'
import type { UsageAccountRef } from './usage-window'

/* ------------------------------------------------------------------ fixtures */

const dirs: string[] = []

afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

function tempHome(): string {
  const dir = mkdtempSync(join(tmpdir(), 'terminaldeck-codex-'))
  dirs.push(dir)
  return dir
}

const account: UsageAccountRef = {
  provider: 'codex',
  id: 'system:codex',
  name: 'Default (Codex)',
  configDir: '/tmp/codex',
}

interface WindowSpec {
  used_percent: number
  window_minutes: number
  resets_at: number
}

/**
 * One `token_count` line, byte-for-byte in the shape the real rollouts on this
 * machine use — key order, null fields and all. Written out rather than
 * assembled loosely so a change to the format shows up as a failing parse here
 * before it shows up as a missing bar.
 */
function tokenCount(
  timestamp: string,
  primary: WindowSpec | null,
  secondary: WindowSpec | null = null,
  planType = 'prolite',
): string {
  const limits = {
    limit_id: 'codex',
    limit_name: null,
    primary,
    secondary,
    credits: null,
    plan_type: planType,
    rate_limit_reached_type: null,
  }
  return JSON.stringify({
    timestamp,
    type: 'event_msg',
    payload: { type: 'token_count', info: null, rate_limits: limits },
  })
}

function writeRollout(home: string, day: string, name: string, lines: string[], mtime?: number): string {
  const [year, month, date] = day.split('-')
  const dir = join(home, 'sessions', year, month, date)
  mkdirSync(dir, { recursive: true })
  const path = join(dir, name)
  writeFileSync(path, `${lines.join('\n')}\n`, 'utf8')
  if (mtime !== undefined) utimesSync(path, mtime / 1000, mtime / 1000)
  return path
}

/* --------------------------------------------------------------- the parse */

describe('reading one rollout line', () => {
  it('reads both windows out of the record Codex actually writes', () => {
    const line = tokenCount(
      '2026-04-30T01:58:04.123Z',
      { used_percent: 33.0, window_minutes: 300, resets_at: 1_777_519_084 },
      { used_percent: 5.0, window_minutes: 10080, resets_at: 1_777_962_625 },
    )
    const parsed = parseRolloutLine(line, 0)
    expect(parsed?.reportedAt).toBe(Date.parse('2026-04-30T01:58:04.123Z'))
    expect(parsed?.windows).toEqual([
      { usedPercent: 33, windowMinutes: 300, resetsAt: 1_777_519_084 },
      { usedPercent: 5, windowMinutes: 10080, resetsAt: 1_777_962_625 },
    ])
  })

  it('drops a window that is not there rather than inventing an empty one', () => {
    const line = tokenCount('2026-06-04T01:54:33.460Z', {
      used_percent: 5.0,
      window_minutes: 43200,
      resets_at: 1_783_130_065,
    })
    expect(parseRolloutLine(line, 0)?.windows).toHaveLength(1)
  })

  it('ignores a line with no rate limits in it', () => {
    const line = JSON.stringify({
      timestamp: '2026-06-04T01:54:33.484Z',
      type: 'event_msg',
      payload: { type: 'task_complete', turn_id: 'x', duration_ms: 8400 },
    })
    expect(parseRolloutLine(line, 0)).toBeNull()
  })

  it('ignores a half-written line, which is what a tail read starts with', () => {
    expect(parseRolloutLine('_count","rate_limits":{"primary":{"used', 0)).toBeNull()
  })

  it('falls back to the file time when the line has no usable timestamp', () => {
    const line = JSON.stringify({
      type: 'event_msg',
      payload: {
        type: 'token_count',
        rate_limits: { primary: { used_percent: 1, window_minutes: 300, resets_at: 1 } },
      },
    })
    expect(parseRolloutLine(line, 1234)?.reportedAt).toBe(1234)
  })
})

/*
 * The investigation this module was built from recorded `primary` as the
 * five-hour window. Two other accounts' rollouts on this same machine disagree
 * — a `free` account's primary is 10080 minutes and a `go` account's is 43200 —
 * so the key name must never decide the period.
 */
describe('classifying by the stated length, not by the key', () => {
  it('does not call a monthly primary a five-hour window', async () => {
    const home = tempHome()
    writeRollout(home, '2026-06-04', 'rollout-a.jsonl', [
      tokenCount(
        '2026-06-04T01:54:33.460Z',
        { used_percent: 5.0, window_minutes: 43200, resets_at: 1_783_130_065 },
        null,
        'go',
      ),
    ])
    const readings = await readCodexUsage(home, account)
    expect(readings).toHaveLength(1)
    expect(readings[0].window).toBe('monthly')
    expect(readings[0].windowMinutes).toBe(43200)
    expect(readings[0].label).toBe('30-day limit')
  })

  it('names each length the way the source stated it', () => {
    expect(describeCodexWindow(300)).toBe('5-hour limit')
    expect(describeCodexWindow(10080)).toBe('Weekly limit')
    expect(describeCodexWindow(43200)).toBe('30-day limit')
    expect(describeCodexWindow(360)).toBe('6-hour limit')
    expect(describeCodexWindow(7)).toBe('7-minute limit')
  })
})

/* ----------------------------------------------------------- tail reading */

describe('finding the last record in a file', () => {
  it('takes the newest record, not the first', async () => {
    const home = tempHome()
    const path = writeRollout(home, '2026-04-30', 'rollout-a.jsonl', [
      tokenCount('2026-04-30T01:00:00.000Z', { used_percent: 7, window_minutes: 300, resets_at: 1_777_300_000 }),
      tokenCount('2026-04-30T01:58:04.123Z', { used_percent: 33, window_minutes: 300, resets_at: 1_777_519_084 }),
    ])
    const found = await readLastRateLimits(path)
    expect(found?.windows[0].usedPercent).toBe(33)
  })

  it('reads only the tail of a large file and still finds the record', async () => {
    const home = tempHome()
    // Roughly 400 KB of conversation after the first record, so the answer is
    // inside the first tail step and the padding before it is never read.
    const padding = Array.from({ length: 2000 }, (_, i) =>
      JSON.stringify({ timestamp: '2026-04-30T01:30:00.000Z', type: 'response_item', payload: { i, text: 'x'.repeat(180) } }),
    )
    const path = writeRollout(home, '2026-04-30', 'rollout-big.jsonl', [
      ...padding,
      tokenCount('2026-04-30T01:58:04.123Z', { used_percent: 33, window_minutes: 300, resets_at: 1_777_519_084 }),
    ])
    expect((await readLastRateLimits(path))?.windows[0].usedPercent).toBe(33)
  })

  it('escalates past the first tail step when the record is further back', async () => {
    const home = tempHome()
    // The record comes first and is then buried under ~400 KB, so it is outside
    // the 256 KB step and only the larger read can reach it.
    const padding = Array.from({ length: 2000 }, (_, i) =>
      JSON.stringify({ timestamp: '2026-04-30T02:00:00.000Z', type: 'response_item', payload: { i, text: 'y'.repeat(180) } }),
    )
    const path = writeRollout(home, '2026-04-30', 'rollout-buried.jsonl', [
      tokenCount('2026-04-30T01:58:04.123Z', { used_percent: 41, window_minutes: 300, resets_at: 1_777_519_084 }),
      ...padding,
    ])
    expect((await readLastRateLimits(path))?.windows[0].usedPercent).toBe(41)
  })

  it('answers nothing for a file that has never carried a rate limit', async () => {
    const home = tempHome()
    const path = writeRollout(home, '2026-04-30', 'rollout-quiet.jsonl', [
      JSON.stringify({ timestamp: '2026-04-30T01:00:00.000Z', type: 'session_meta', payload: { id: 'x' } }),
    ])
    expect(await readLastRateLimits(path)).toBeNull()
  })
})

/* ------------------------------------------------------------- assembling */

describe('reading an account', () => {
  it('carries the account, the window, the fraction, the reset and both times', async () => {
    const home = tempHome()
    writeRollout(home, '2026-04-30', 'rollout-a.jsonl', [
      tokenCount(
        '2026-04-30T01:58:04.123Z',
        { used_percent: 33.0, window_minutes: 300, resets_at: 1_777_519_084 },
        { used_percent: 5.0, window_minutes: 10080, resets_at: 1_777_962_625 },
      ),
    ])
    const now = Date.parse('2026-04-30T02:00:00.000Z')
    const readings = await readCodexUsage(home, account, now)

    expect(readings.map((entry) => entry.window)).toEqual(['five-hour', 'weekly'])
    const five = readings[0]
    expect(five.account).toEqual(account)
    expect(five.used).toEqual({ state: 'reported', fraction: 0.33 })
    expect(five.resets).toEqual({ state: 'at', at: 1_777_519_084_000 })
    expect(five.source).toBe('codex-rollout')
    // The two clocks are the point: observed now, reported when the turn ran.
    expect(five.observedAt).toBe(now)
    expect(five.reportedAt).toBe(Date.parse('2026-04-30T01:58:04.123Z'))
    expect(five.reportedAt).toBeLessThan(five.observedAt)
  })

  it('reports nothing, not zero, when Codex has never run under this account', async () => {
    const readings = await readCodexUsage(tempHome(), account)
    expect(readings).toEqual([])
  })

  it('reports nothing for a home that does not exist at all', async () => {
    expect(await readCodexUsage(join(tmpdir(), 'terminaldeck-codex-absent'), account)).toEqual([])
  })

  it('takes the newest turn even when an older file was touched last', async () => {
    const home = tempHome()
    // The stale file is the one with the newest mtime, so a reader that trusted
    // the filesystem's clock over the transcript's would answer 9.
    writeRollout(
      home,
      '2026-04-30',
      'rollout-old.jsonl',
      [tokenCount('2026-04-30T01:00:00.000Z', { used_percent: 9, window_minutes: 300, resets_at: 1_777_300_000 })],
      Date.parse('2026-05-01T00:00:00.000Z'),
    )
    writeRollout(
      home,
      '2026-04-30',
      'rollout-new.jsonl',
      [tokenCount('2026-04-30T05:00:00.000Z', { used_percent: 61, window_minutes: 300, resets_at: 1_777_519_084 })],
      Date.parse('2026-04-30T23:00:00.000Z'),
    )
    const readings = await readCodexUsage(home, account)
    expect(readings[0].used).toEqual({ state: 'reported', fraction: 0.61 })
  })

  it('looks in archived sessions too, because archiving is not ageing', async () => {
    const home = tempHome()
    const dir = join(home, 'archived_sessions')
    mkdirSync(dir, { recursive: true })
    writeFileSync(
      join(dir, 'rollout-archived.jsonl'),
      `${tokenCount('2026-04-30T04:00:00.000Z', { used_percent: 12, window_minutes: 300, resets_at: 1_777_519_084 })}\n`,
      'utf8',
    )
    const readings = await readCodexUsage(home, account)
    expect(readings[0].used).toEqual({ state: 'reported', fraction: 0.12 })
  })

  it('walks the dated tree newest first rather than crawling all of it', async () => {
    const home = tempHome()
    writeRollout(home, '2025-01-01', 'rollout-ancient.jsonl', ['{}'])
    writeRollout(home, '2026-06-04', 'rollout-recent.jsonl', ['{}'])
    const found = await findCodexRollouts(home)
    expect(found[0]).toContain(join('2026', '06', '04'))
  })
})
