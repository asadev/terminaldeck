import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog } from './action-log'
import { ConsentBroker } from './consent'
import { DeckControl } from './control'
import type { DeckSurface } from './surface'
import type { CreateSessionInput, SessionMeta } from '../../shared/types'

/**
 * A session the copilot starts says so, and says which turn started it.
 *
 * Two fields, three lines of code in `sessions.start`, and both of them fail
 * *silently* if they go:
 *
 *  - **`origin`** is what the sidebar groups on. Without it the session is
 *    still drawn, still clickable and still correct in every respect except
 *    that it sits in the middle of somebody's own project run with nothing
 *    saying the machine started it — which is the one thing an app that can
 *    spawn processes on its own must not do.
 *  - **`originRunId`** is the action-log row for the turn. Without it "why does
 *    this exist" has no answer, and pairing a session with a turn falls back to
 *    matching timestamps, which is a guess and a wrong one for any two starts
 *    inside the same second.
 *
 * The id has to be *the row's own*, not a second identifier: a second one would
 * have to be written into the log to be resolvable, and then the log would
 * carry two ids for one event.
 */

function surface(started: CreateSessionInput[]): DeckSurface {
  const created: SessionMeta[] = []
  return {
    listSessions: () => created,
    sessionStatus: () => null,
    startSession: async (input) => {
      started.push(input)
      const meta: SessionMeta = {
        id: `session-${started.length}`,
        cwd: input.cwd,
        title: 'api',
        provider: 'claude',
        exitCode: null,
        createdAt: 1_000,
      }
      created.push(meta)
      return meta
    },
    writeToSession: () => undefined,
    killSession: () => undefined,
    sessionScreen: async () => null,
    listProjects: () => [{ path: '/work/api', lastOpenedAt: 1 }],
    gitStatus: async () => ({}),
    alerts: async () => ({}),
    readSettings: () => ({ settings: {}, preferences: {} }),
    writeSettings: (patch) => patch as Record<string, string | number | boolean>,
    writePreferences: (patch) => patch,
    snapshotSettings: () => ({ path: '/tmp/last-good.json', at: 1 }),
    newestTranscript: async () => null,
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
  }
}

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-provenance-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

function build(started: CreateSessionInput[]): DeckControl {
  return new DeckControl({
    surface: surface(started),
    log: new ActionLog({ dir }),
    // Never reached: `sessions.start` is an act-tier tool. Present because the
    // dispatcher requires one, and refusing everything is the honest stand-in.
    consent: new ConsentBroker({ ask: () => false }),
  })
}

describe('sessions.start', () => {
  it('labels the session as the copilot’s', async () => {
    const started: CreateSessionInput[] = []
    const result = await build(started).call('sessions.start', { cwd: '/work/api' })

    expect(result.ok).toBe(true)
    expect(started).toHaveLength(1)
    expect(started[0].origin).toBe('copilot')
  })

  it('points the session at the very row this call wrote', async () => {
    const started: CreateSessionInput[] = []
    const result = await build(started).call('sessions.start', { cwd: '/work/api' })

    expect(started[0].originRunId).toBe(result.row.id)
    // And the row is about this tool, so following the id lands on something
    // that explains the session rather than on an unrelated turn.
    expect(result.row.tool).toBe('sessions.start')
  })

  it('gives two starts two different turns', async () => {
    const started: CreateSessionInput[] = []
    const control = build(started)
    const first = await control.call('sessions.start', { cwd: '/work/api' })
    const second = await control.call('sessions.start', { cwd: '/work/api' })

    expect(first.row.id).not.toBe(second.row.id)
    expect(started[0].originRunId).toBe(first.row.id)
    expect(started[1].originRunId).toBe(second.row.id)
  })

  it('changes nothing else about how the session runs', async () => {
    // `origin` is a label and never a permission. The folder and the agent are
    // exactly what was asked for; `src/main/session-origin.test.ts` proves the
    // same thing one layer down, against a real pty.
    const started: CreateSessionInput[] = []
    await build(started).call('sessions.start', { cwd: '/work/api', provider: 'claude' })

    expect(started[0].cwd).toBe('/work/api')
    expect(started[0].provider).toBe('claude')
  })
})
