import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { SessionMeta, SessionStatus } from '../shared/types'
import { PtyManager, type RemovalReason } from './pty-manager'

/**
 * The announcement that a session is gone, against a real process.
 *
 * ## The ghost this closes
 *
 * Watched on 2026-08-18 in the copilot capability audit: the copilot was asked to
 * stop a session it had started. It called `sessions_stop`, `sessions_list` came
 * back holding only the copilot itself — and *"Copilot sessions → Session 1"* was
 * still sitting in the sidebar. Nothing could be done with that row. Typing into
 * it went nowhere, re-attaching found no scrollback, and the only way to be rid
 * of it was to quit the app.
 *
 * The cause is a shape rather than a slip. The window learned about endings from
 * exactly one place: `closeTabNow`, which kills the pty and removes the row in
 * the same breath. So an ending it caused itself worked, and an ending caused by
 * anything else — the copilot, a paired phone, a routine — left the row behind.
 * There was no channel to hear it on.
 *
 * ## Why the removal is not `onExit`
 *
 * Because they are different facts and only one of them means the row should go.
 * A process that ends on its own **stays** in the manager with an exit code and
 * keeps its scrollback, deliberately: reading what an agent printed before it
 * finished is the reason that tab is still worth having. Reusing the exit for
 * "take the row away" would delete the pane somebody is reading at the moment
 * their agent finishes, which is a worse bug than the one being fixed.
 *
 * So the pinned claim is a pair, and the second half is the one that would be
 * lost first if somebody simplified this: **kill announces, exit does not.**
 *
 * A real pty, because the claim is about what happens to a session that actually
 * exists, and because the thing it is easiest to get wrong is the ordering —
 * `kill` deletes from the map and returns while the process lives on until the
 * OS reaps it. The process is one that exits immediately; nothing here depends
 * on what it prints.
 */

const windows = process.platform === 'win32'
const COMMAND = windows ? 'cmd.exe' : '/bin/sh'
/* Long enough to still be alive when it is killed. `exit 0` would race. */
const ARGS = windows ? ['/c', 'timeout /t 30'] : ['-c', 'sleep 30']

let dir: string
let ptys: PtyManager
let removed: Array<{ id: string; reason: RemovalReason }> = []
let exited: string[] = []

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-removed-'))
  removed = []
  exited = []
  ptys = new PtyManager(
    () => undefined,
    (id: string) => exited.push(id),
    (_id: string, _status: SessionStatus) => undefined,
    (id: string, reason: RemovalReason) => removed.push({ id, reason }),
  )
})

afterEach(async () => {
  ptys.killAll()
  await ptys.drain()
  rmSync(dir, { recursive: true, force: true })
})

function start(): SessionMeta {
  return ptys.create(
    { cwd: dir, cols: 80, rows: 24 },
    { provider: 'shell', command: COMMAND, args: ARGS, path: process.env.PATH ?? '' },
  )
}

describe('a session leaving the manager', () => {
  it('announces the removal at the moment it stops being listable', async () => {
    const meta = start()
    expect(ptys.list().map((s) => s.id)).toContain(meta.id)

    ptys.kill(meta.id)

    // The two facts arrive together, and that is the point: the announcement is
    // useful precisely because it is simultaneous with the session disappearing
    // from `list()`. The exit is still minutes of OS scheduling away.
    expect(removed).toEqual([{ id: meta.id, reason: 'stopped' }])
    expect(ptys.list().map((s) => s.id)).not.toContain(meta.id)
    await ptys.drain()
  })

  it('says nothing when a process merely exits, because the session is still there', async () => {
    /*
     * The half that must not be simplified away. A session whose process ended
     * keeps its row: its scrollback is still held, `list()` still returns it with
     * an exit code, and somebody is reading what it printed.
     */
    const meta = ptys.create(
      { cwd: dir, cols: 80, rows: 24 },
      {
        provider: 'shell',
        command: COMMAND,
        args: windows ? ['/c', 'exit'] : ['-c', 'exit 0'],
        path: process.env.PATH ?? '',
      },
    )
    await ptys.drain()

    expect(exited).toContain(meta.id)
    expect(removed).toEqual([])
    expect(ptys.list().map((s) => s.id)).toContain(meta.id)
  })

  it('marks an account switch as a replacement rather than a removal', async () => {
    /*
     * The one kill whose row must stay. Changing the account a session runs on
     * stops the process and starts another in its place, and to the person it is
     * still *this* session, in the same tab, with the name they gave it. The
     * renderer's swap finds the old row by id and deliberately leaves the list
     * alone when it cannot — so an announced removal would race that swap, and on
     * the losing side the tab disappears mid-switch.
     *
     * The reason travels rather than the caller filtering, so the fact is carried
     * by the one thing that knows it and every listener gets the same answer.
     */
    const meta = start()
    ptys.kill(meta.id, 'replaced')
    expect(removed).toEqual([{ id: meta.id, reason: 'replaced' }])
    await ptys.drain()
  })

  it('says nothing for an id it was never holding', async () => {
    // A double close, or a stop racing an exit. Announcing twice would be a
    // second removal for a row that has already gone, which the renderer would
    // absorb — but the honest shape is that the manager only reports what it
    // actually did.
    ptys.kill('never-existed')
    expect(removed).toEqual([])
  })
})
