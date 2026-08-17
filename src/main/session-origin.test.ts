import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { SessionMeta, SessionStatus } from '../shared/types'
import { PtyManager } from './pty-manager'

/**
 * `origin` on a session, against a real process.
 *
 * This is three conditional spreads in `PtyManager.create` and it would be very
 * easy to delete by accident, so it is pinned here rather than reasoned about.
 * Two things depend on it and both fail silently if it goes: the sidebar's
 * "Copilot sessions" grouping shows nothing, and — worse — the routine engine's
 * loop guard loses the provenance it uses to refuse to be started by its own
 * work, which turns "when a session finishes, start a session" back into a
 * machine that never stops.
 *
 * A real pty, because the claim is about what `create` puts on the metadata of
 * a session that actually exists. The process is one that exits immediately;
 * nothing here depends on what it prints.
 */

const windows = process.platform === 'win32'
const COMMAND = windows ? 'cmd.exe' : '/bin/sh'
const ARGS = windows ? ['/c', 'exit'] : ['-c', 'exit 0']

let dir: string
let ptys: PtyManager
const exits: string[] = []

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-origin-'))
  exits.length = 0
  ptys = new PtyManager(
    () => undefined,
    (id: string) => exits.push(id),
    (_id: string, _status: SessionStatus) => undefined,
  )
})

afterEach(async () => {
  ptys.killAll()
  await ptys.drain()
  rmSync(dir, { recursive: true, force: true })
})

function start(input: Partial<Parameters<PtyManager['create']>[0]> = {}): SessionMeta {
  return ptys.create(
    { cwd: dir, cols: 80, rows: 24, ...input },
    { provider: 'shell', command: COMMAND, args: ARGS, path: process.env.PATH ?? '' },
  )
}

describe('session origin', () => {
  it('carries the copilot label and its provenance onto the session', () => {
    const meta = start({
      origin: 'copilot',
      originRoutineId: 'nightly-sweep',
      originRunId: 'run-1',
    })
    expect(meta.origin).toBe('copilot')
    expect(meta.originRoutineId).toBe('nightly-sweep')
    expect(meta.originRunId).toBe('run-1')
    expect(ptys.list()[0].origin).toBe('copilot')
  })

  it('leaves the keys off a session nobody labelled', () => {
    const meta = start()
    // Absent, not `undefined`: a renderer cannot tell the two apart after JSON,
    // and "no origin" has to survive the crossing as the same thing it was.
    expect('origin' in meta).toBe(false)
    expect('originRoutineId' in meta).toBe(false)
    expect('originRunId' in meta).toBe(false)
  })

  it('does not change how the session runs', () => {
    // `origin` is a label and nothing else — the confinement, the profile and
    // the folder rules all apply to a copilot session exactly as they do to
    // yours. If this ever became a permission, this is where it would show up.
    const mine = start()
    const theirs = start({ origin: 'copilot' })
    expect(theirs.cwd).toBe(mine.cwd)
    expect(theirs.provider).toBe(mine.provider)
    expect(theirs.profileId).toBe(mine.profileId)
  })
})
