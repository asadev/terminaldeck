import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { appendCopilotAction, copilotPaths } from '../copilot-home'
import { ACTION_LOG_FILE, ActionLog, MAX_LOGGED_STRING, scrubArgs, type ActionRow } from './action-log'

/**
 * The audit file: what goes in it, what never does, and what happens when it
 * gets big or when somebody else writes to it.
 *
 * The last one is not hypothetical. `copilot-home.ts` appends its own lifecycle
 * lines to this exact path, so there are two writers and one file, and the
 * final describe here is the interop test that keeps them agreeing.
 */

let dir = ''

function row(overrides: Partial<ActionRow> = {}): Omit<ActionRow, 'v'> {
  return {
    at: '2026-08-17T09:00:00.000Z',
    action: 'tool.projects.list',
    detail: 'List the open projects — done',
    id: 'call-1',
    tool: 'projects.list',
    tier: 'read',
    args: {},
    outcome: 'ok',
    confirmed: { required: false, granted: false, by: null, at: null, reason: null },
    ms: 3,
    result: { count: 2 },
    error: null,
    ...overrides,
  }
}

function lines(file: string): string[] {
  try {
    return readFileSync(file, 'utf8').split('\n').filter((line) => line.length > 0)
  } catch {
    return []
  }
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-control-log-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('what a row looks like', () => {
  it('writes one line of JSON per call', () => {
    const log = new ActionLog({ dir })
    log.record(row())
    log.record(row({ id: 'call-2' }))

    const written = lines(log.file)
    expect(written).toHaveLength(2)
    expect(JSON.parse(written[0])).toMatchObject({
      v: 1,
      at: '2026-08-17T09:00:00.000Z',
      action: 'tool.projects.list',
      tool: 'projects.list',
      tier: 'read',
      outcome: 'ok',
    })
  })

  it('says whether a human confirmed it, on every row', () => {
    const log = new ActionLog({ dir })
    log.record(row())
    // Not nullable. "Nobody confirmed this" is the honest reading of a call that
    // was never put to anyone, and a null here would invite a reader to treat
    // absent as approved.
    expect(JSON.parse(lines(log.file)[0]).confirmed).toEqual({
      required: false,
      granted: false,
      by: null,
      at: null,
      reason: null,
    })
  })

  it('keeps the file readable when one line is torn', () => {
    const log = new ActionLog({ dir })
    log.record(row())
    writeFileSync(log.file, `${readFileSync(log.file, 'utf8')}{"half a row"\n`, 'utf8')
    log.record(row({ id: 'call-3' }))

    // A row half-written when the machine lost power is one bad line in a file
    // whose others are fine.
    expect(log.tail(10).map((entry) => entry.id)).toEqual(['call-1', 'call-3'])
  })
})

describe('what never reaches the file', () => {
  it('drops the value of any secret-looking key', () => {
    expect(scrubArgs({ token: 'abc123', apiKey: 'x', authorization: 'Bearer y', cwd: '/work' })).toEqual({
      token: '[redacted]',
      apiKey: '[redacted]',
      authorization: '[redacted]',
      cwd: '/work',
    })
  })

  it('catches a credential by shape inside prose the copilot composed', () => {
    const scrubbed = scrubArgs({ text: 'use sk-ant-api03-QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ please' })
    expect(scrubbed.text).not.toContain('sk-ant-api03')
    expect(scrubbed.text).toContain('[redacted]')
  })

  it('catches one in a log.note too, which is prose written straight into this file', () => {
    /*
     * `log.note` is the tool that replaced the copilot's direct write to this
     * log, so its argument is the one piece of free text in the catalogue whose
     * whole purpose is to become a row somebody reads. If `note` ever fell out
     * of the prose list it would be recorded verbatim — and the copilot's own
     * `CLAUDE.md` promises the person a check behind its "never repeat
     * something that looks like a credential" rule.
     */
    const scrubbed = scrubArgs({
      note: 'the deploy failed, GH_TOKEN=ghp_QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ is stale',
    })
    expect(scrubbed.note).not.toContain('ghp_QQQQ')
    expect(scrubbed.note).toContain('[redacted]')
    // And the rest of the sentence survives — a row that redacted itself into
    // uselessness would be a worse audit trail than one that never existed.
    expect(scrubbed.note).toContain('the deploy failed')
  })

  it('leaves the user’s own paths and ids alone', () => {
    /*
     * `redact.ts` also folds identity — `/Users/asad` becomes `/Users/<user>` —
     * and runs an entropy sweep that would take a session UUID with it. Both
     * are right for a support bundle and wrong here: this file lives in the
     * user's own application-support directory, beside `state.json`, and its
     * whole job is to let them audit their own machine. A log whose session ids
     * are `[redacted]` cannot answer the question it was written for.
     */
    const scrubbed = scrubArgs({
      cwd: '/Users/asad/Projects/terminaldeck',
      sessionId: '0f9c1d2e-4a5b-6c7d-8e9f-a0b1c2d3e4f5',
    })
    expect(scrubbed.cwd).toBe('/Users/asad/Projects/terminaldeck')
    expect(scrubbed.sessionId).toBe('0f9c1d2e-4a5b-6c7d-8e9f-a0b1c2d3e4f5')
  })

  it('caps a long string rather than copying a conversation into the log', () => {
    const scrubbed = scrubArgs({ note: 'x'.repeat(MAX_LOGGED_STRING * 2) })
    expect(String(scrubbed.note).length).toBeLessThan(MAX_LOGGED_STRING + 40)
    expect(String(scrubbed.note)).toContain('chars]')
  })

  it('summarises a nested shape instead of serialising it', () => {
    expect(scrubArgs({ patch: { theme: 'light', deep: { a: 1 } } })).toEqual({
      patch: { theme: 'light', deep: '[object]' },
    })
  })

  it('records a call whose arguments were pathological, minus the arguments', () => {
    const log = new ActionLog({ dir })
    log.record(row({ args: { note: 'y'.repeat(200_000) } }))

    const written = JSON.parse(lines(log.file)[0]) as ActionRow
    // The fact that a call happened is the part of a row that must never be
    // lost, so the row survives with a note where its arguments were.
    expect(written.tool).toBe('projects.list')
    expect(written.args).toEqual({ note: 'arguments were too large to record' })
  })
})

describe('when it gets big', () => {
  it('rolls to a single kept generation and keeps appending', () => {
    const log = new ActionLog({ dir, maxBytes: 4096, keep: 1 })
    for (let i = 0; i < 200; i += 1) log.record(row({ id: `call-${i}` }))

    expect(statSync(log.file).size).toBeLessThanOrEqual(4096)
    expect(statSync(`${log.file}.1`).size).toBeGreaterThan(0)
  })

  it('reads back across the rolled generation', () => {
    const log = new ActionLog({ dir, maxBytes: 4096, keep: 1 })
    for (let i = 0; i < 200; i += 1) log.record(row({ id: `call-${i}` }))

    // A busy afternoon can roll the file; a pane that only read the live one
    // would show the last ten minutes of a story that started this morning. So
    // the assertion is that the tail reaches *past* the live file — with one
    // kept generation there is a hard ceiling on how far back it can go, and
    // asking for sixty rows out of a file that holds a couple of dozen is a
    // request for "everything you still have".
    const live = lines(log.file).length
    const tail = log.tail(60)

    expect(tail.length).toBeGreaterThan(live)
    expect(tail.at(-1)?.id).toBe('call-199')
    // Nothing older than the rolled generation is claimed to exist.
    expect(tail.length).toBe(live + lines(`${log.file}.1`).length)
  })

  it('returns nothing for a nonsense count instead of the entire log', () => {
    const log = new ActionLog({ dir })
    log.record(row())
    // `slice(-0)` is the whole array, which is how "give me no lines" once
    // returned every line of every generation in `app-log.ts`.
    expect(log.tail(0)).toEqual([])
    expect(log.tail(-5)).toEqual([])
    expect(log.tail(Number.NaN)).toEqual([])
  })
})

describe('when it cannot be written', () => {
  it('marks itself broken instead of throwing at the caller', () => {
    // A file where the directory should be: `mkdirSync` fails, and so does
    // every append after it.
    const blocked = join(dir, 'blocked')
    writeFileSync(blocked, 'not a directory', 'utf8')
    const log = new ActionLog({ dir: blocked })

    expect(() => log.record(row())).not.toThrow()
    // Reported rather than silent: a copilot that keeps working while nothing
    // records it is a state the status channel has to be able to describe.
    expect(log.broken).toBe(true)
  })
})

describe('sharing the file with copilot-home.ts', () => {
  it('reads the lifecycle rows that module writes', () => {
    const paths = copilotPaths(dir)
    appendCopilotAction(paths, { action: 'home.created', detail: 'Made the copilot folder' })

    const log = new ActionLog({ dir: paths.log })
    log.record(row())

    const tail = log.tail(10)
    expect(tail).toHaveLength(2)
    // One file, one convention: `at`, `action` and `detail` mean the same thing
    // in both rows, so a pane can render them in one list.
    expect(tail[0].action).toBe('home.created')
    expect(tail[0].detail).toBe('Made the copilot folder')
    expect(tail[1].action).toBe('tool.projects.list')
    expect(tail.every((entry) => typeof entry.at === 'string')).toBe(true)
  })

  it('writes to the path that module defines, not a second one', () => {
    const paths = copilotPaths(dir)
    const log = new ActionLog({ dir: paths.log })
    log.record(row())
    // Composing the path independently is how the writer and the reader end up
    // in different folders after somebody moves the layout.
    expect(log.file).toBe(paths.actions)
    expect(log.file.endsWith(ACTION_LOG_FILE)).toBe(true)
  })

  it('does not lose a line the other writer appended after this one started', () => {
    /*
     * The reason the size is read rather than remembered.
     *
     * `AppLog` tracks bytes in memory and is right to — it owns its file. Here
     * a cached count goes stale the instant `appendCopilotAction` writes, and a
     * stale count means rolling at the wrong moment: either an oversized file
     * or a roll that throws away lines somebody else had just added.
     */
    const paths = copilotPaths(dir)
    const log = new ActionLog({ dir: paths.log, maxBytes: 4096, keep: 1 })
    log.record(row())
    for (let i = 0; i < 50; i += 1) {
      appendCopilotAction(paths, { action: 'session.started', detail: `session ${i}` })
    }
    log.record(row({ id: 'after' }))

    const tail = log.tail(200)
    expect(tail.filter((entry) => entry.action === 'session.started')).toHaveLength(50)
    expect(tail.at(-1)?.id).toBe('after')
  })
})
