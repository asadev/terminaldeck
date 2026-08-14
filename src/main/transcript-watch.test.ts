import { mkdtempSync, mkdirSync, appendFileSync, realpathSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { formatUsd } from './cost'
import { encodeProjectPath, TranscriptWatcher, type ProjectSummary } from './transcript'

/**
 * A scratch config directory, spelled the way the OS will spell it back.
 *
 * `os.tmpdir()` is `/var/folders/…` on macOS, which is a symlink to
 * `/private/var/…`, and `C:\Users\RUNNER~1\AppData\Local\Temp` on a Windows
 * runner, which is an 8.3 short name. A file watcher reports the resolved path,
 * so handing it the unresolved one makes every event arrive under a name the
 * watcher's own bookkeeping does not recognise. Resolved once, here, rather
 * than debugged again per test.
 */
function scratch(prefix: string): string {
  return realpathSync(mkdtempSync(join(tmpdir(), prefix)))
}

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

/**
 * Wait until the watcher itself reports something, rather than sleeping a span
 * and hoping.
 *
 * These tests drive a real `TranscriptWatcher` over a real directory, so every
 * append reaches it through an OS filesystem notification — and that
 * notification carries no latency guarantee. It usually lands in a few
 * milliseconds; on a machine running the whole suite in parallel it can take
 * hundreds. A fixed `sleep` therefore encodes a guess about machine speed into
 * a pass/fail, which is exactly what made the `maxSessions` case below fail
 * about one run in four: instrumenting the watcher showed the append event had
 * simply not been delivered yet when the assertions ran, so the file was never
 * enqueued and never read.
 *
 * Waiting on the condition makes the outcome depend on what the watcher did
 * rather than on how busy the machine was — a slow machine now gets the same
 * answer, just later. The ceiling is not a tuned timeout: it exists only so a
 * watcher that genuinely never fires reports a readable failure instead of
 * hanging until vitest kills the test.
 */
async function until(
  what: string,
  watcher: TranscriptWatcher,
  ready: (summary: ProjectSummary) => boolean,
  ceilingMs = 8_000,
): Promise<ProjectSummary> {
  const deadline = Date.now() + ceilingMs
  for (;;) {
    const summary = watcher.summary()
    if (ready(summary)) return summary
    if (Date.now() >= deadline) {
      throw new Error(
        `waited ${ceilingMs}ms for ${what} and it never happened; ` +
          `requests=${summary.requests} sessions=[${summary.sessions
            .map((s) => s.sessionId)
            .join(' ')}]`,
      )
    }
    await new Promise((r) => setTimeout(r, 10))
  }
}

describe('TranscriptWatcher against a live file', () => {
  it('picks up appends incrementally', async () => {
    const config = scratch('terminaldeck-cost-')
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
    // lines the way a real multi-block response is. Each is waited for
    // separately, which is also what makes them two distinct updates rather
    // than one coalesced batch.
    appendFileSync(file, line('m2', 1_000_000))
    await until('the second request to be picked up', watcher, (s) => s.requests >= 2)

    appendFileSync(file, line('m3', 1_000_000))
    appendFileSync(file, line('m3', 1_000_000))
    appendFileSync(file, line('m3', 1_000_000))
    const final = await until('the third request to be picked up', watcher, (s) => s.requests >= 3)
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
    const config = scratch('terminaldeck-cost-sum-')
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
    const config = scratch('terminaldeck-cost-cap-')
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

    // A third session starts while we are watching. `prune` runs at the end of
    // the same drain that reads the new file, so the moment sess-c is visible
    // the cap has already been applied — there is no window in which all three
    // are resident for this to race against.
    appendFileSync(join(dir, 'sess-c.jsonl'), line('c1', 10, { timestamp: '2026-08-11T12:00:00.000Z' }))

    const summary = await until('the third session to be picked up', watcher, (s) =>
      s.sessions.some((session) => session.sessionId === 'sess-c'),
    )
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
    const config = scratch('terminaldeck-cost-empty-')
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
