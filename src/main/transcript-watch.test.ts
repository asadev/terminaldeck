import { mkdtempSync, mkdirSync, appendFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { formatUsd } from './cost'
import { encodeProjectPath, TranscriptWatcher, type ProjectSummary } from './transcript'

function line(
  id: string,
  output: number,
  extra: { model?: string; timestamp?: string } = {},
): string {
  return `${JSON.stringify({
    type: 'assistant',
    uuid: `${id}-u`,
    requestId: `req_${id}`,
    timestamp: extra.timestamp ?? new Date().toISOString(),
    cwd: '/fake/project',
    sessionId: 'sess-live',
    isSidechain: false,
    message: {
      id,
      model: extra.model ?? 'claude-opus-5',
      role: 'assistant',
      usage: {
        input_tokens: 1,
        output_tokens: output,
        cache_creation_input_tokens: 1000,
        cache_read_input_tokens: 5000,
        cache_creation: { ephemeral_1h_input_tokens: 1000, ephemeral_5m_input_tokens: 0 },
      },
    },
  })}\n`
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

describe('TranscriptWatcher against a live file', () => {
  it('picks up appends incrementally', async () => {
    const config = mkdtempSync(join(tmpdir(), 'terminaldeck-cost-'))
    const cwd = '/fake/project'
    const dir = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })
    const file = join(dir, 'sess-live.jsonl')

    // Pre-existing history, present before the watcher starts.
    appendFileSync(file, line('m1', 1_000_000))

    const updates: ProjectSummary[] = []
    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      debounceMs: 50,
      onUpdate: (s) => updates.push(s),
    })
    await watcher.start()

    const afterScan = watcher.summary()
    console.log('after initial scan:', afterScan.requests, formatUsd(afterScan.cost.cost.total))
    expect(afterScan.requests).toBe(1)
    expect(afterScan.scanning).toBe(false)
    expect(afterScan.activeSessionId).toBe('sess-live')

    // Two more requests arrive while we watch, the second split across three
    // lines the way a real multi-block response is.
    appendFileSync(file, line('m2', 1_000_000))
    await sleep(250)
    appendFileSync(file, line('m3', 1_000_000))
    appendFileSync(file, line('m3', 1_000_000))
    appendFileSync(file, line('m3', 1_000_000))
    await sleep(400)

    const final = watcher.summary()
    console.log('after appends:', final.requests, formatUsd(final.cost.cost.total))
    console.log('updates emitted:', updates.length)
    console.log('session:', final.sessions[0]?.sessionId, 'ctx:', final.sessions[0]?.context)
    watcher.stop()

    expect(final.requests).toBe(3)
    // 3 x 1M output @ $25 + cache write/read crumbs.
    expect(final.cost.cost.output).toBeCloseTo(75, 6)
    expect(updates.length).toBeGreaterThan(1)
  }, 10_000)

  it('reports a project total that equals the sum of its sessions', async () => {
    // Regression: the project total was computed by pooling every session's raw
    // tokens and re-pricing them at `Date.now()`, so historical work was valued
    // at today's rates and the headline number disagreed with the sessions
    // listed underneath it. This session ran after Sonnet 5's introductory rate
    // ended, so pricing it "now" would charge the wrong card.
    const config = mkdtempSync(join(tmpdir(), 'terminaldeck-cost-sum-'))
    const cwd = '/fake/project'
    const dir = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })
    appendFileSync(
      join(dir, 'sess-old.jsonl'),
      line('m1', 1_000_000, { model: 'claude-sonnet-5', timestamp: '2026-10-01T10:00:00.000Z' }),
    )

    const watcher = new TranscriptWatcher({ cwd, configDir: config, debounceMs: 20, onUpdate: () => {} })
    await watcher.start()
    const summary = watcher.summary()
    watcher.stop()

    const sessionTotal = summary.sessions.reduce((sum, s) => sum + s.cost.cost.total, 0)
    console.log('project:', summary.cost.cost.total, 'sessions:', sessionTotal)
    expect(summary.sessions).toHaveLength(1)
    expect(summary.cost.cost.total).toBeCloseTo(sessionTotal, 10)
    // Standard Sonnet 5 output is $15/M; the introductory $10/M had expired.
    expect(summary.cost.cost.output).toBeCloseTo(15, 6)
  }, 10_000)

  it('caps how many sessions it keeps resident as new ones appear', async () => {
    // Regression: `maxSessions` was only applied to the initial scan, so a
    // watcher left running on a busy project accumulated a tail and an
    // aggregator — each holding every request id it had ever seen — forever.
    const config = mkdtempSync(join(tmpdir(), 'terminaldeck-cost-cap-'))
    const cwd = '/fake/project'
    const dir = join(config, 'projects', encodeProjectPath(cwd))
    mkdirSync(dir, { recursive: true })
    appendFileSync(join(dir, 'sess-a.jsonl'), line('a1', 10, { timestamp: '2026-08-11T10:00:00.000Z' }))
    appendFileSync(join(dir, 'sess-b.jsonl'), line('b1', 10, { timestamp: '2026-08-11T11:00:00.000Z' }))

    const watcher = new TranscriptWatcher({
      cwd,
      configDir: config,
      debounceMs: 30,
      maxSessions: 2,
      onUpdate: () => {},
    })
    await watcher.start()
    expect(watcher.summary().sessions).toHaveLength(2)

    // A third session starts while we are watching.
    appendFileSync(join(dir, 'sess-c.jsonl'), line('c1', 10, { timestamp: '2026-08-11T12:00:00.000Z' }))
    await sleep(400)

    const summary = watcher.summary()
    watcher.stop()
    const ids = summary.sessions.map((s) => s.sessionId)
    console.log('resident sessions:', ids)
    expect(summary.sessions).toHaveLength(2)
    // The two most recently active survive; the oldest is dropped.
    expect(ids).toContain('sess-c')
    expect(ids).toContain('sess-b')
    expect(ids).not.toContain('sess-a')
  }, 10_000)

  it('survives a project that has never been opened in Claude Code', async () => {
    const config = mkdtempSync(join(tmpdir(), 'terminaldeck-cost-empty-'))
    const updates: ProjectSummary[] = []
    const watcher = new TranscriptWatcher({
      cwd: '/nowhere/at/all',
      configDir: config,
      debounceMs: 20,
      onUpdate: (s) => updates.push(s),
    })
    await watcher.start()
    const summary = watcher.summary()
    console.log('empty project:', summary.requests, summary.sessions.length, summary.activeSessionId)
    watcher.stop()
    expect(summary.requests).toBe(0)
    expect(summary.sessions).toEqual([])
    expect(summary.activeSessionId).toBeNull()
    expect(summary.cost.cost.total).toBe(0)
  }, 10_000)
})
