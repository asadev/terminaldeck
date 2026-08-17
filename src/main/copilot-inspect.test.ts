import { appendFileSync, mkdirSync, mkdtempSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/*
 * `copilot-inspect.ts` imports `shell` from electron for its one reveal
 * handler. Nothing below goes near it, but the import is evaluated when the
 * module loads, and there is no Electron in a vitest run — the same stub
 * `app-log.test.ts` uses, for the same reason.
 */
vi.mock('electron', () => ({
  shell: { openPath: async () => '', showItemInFolder: () => {} },
}))

import { appendCopilotAction, copilotPaths, scaffoldCopilotHome } from './copilot-home'
import {
  deleteMemoryFact,
  isMemoryName,
  parseActionRow,
  parseFrontMatter,
  readActionLog,
  readMemory,
  readMemoryFact,
  MAX_MEMORY_READ_BYTES,
} from './copilot-inspect'

/**
 * The Copilot pane's reads, against real files.
 *
 * Every claim the pane prints about the copilot is a claim about something on
 * disk, so these run on a real temporary `<userData>` rather than on mocks. The
 * two that matter most are at the bottom: the memory name cannot be talked into
 * naming a file outside `memory/`, and the action log is reported as living
 * outside the folder the copilot may write to. Both are sentences the pane puts
 * on screen, and a sentence on screen that nothing checks is the shape of every
 * defect this repository has paid for.
 */

let dir: string

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'copilot-inspect-'))
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('front matter', () => {
  it('reads the block the copilot is instructed to write', () => {
    const parsed = parseFrontMatter(
      [
        '---',
        'name: science_locus_uses_pnpm',
        'description: "science-locus builds with pnpm, not npm"',
        'type: convention',
        'scope: ~/Projects/science-locus',
        'verified: 2026-08-17',
        '---',
        '',
        'The lockfile is pnpm-lock.yaml.',
      ].join('\n'),
    )
    expect(parsed).toEqual({
      name: 'science_locus_uses_pnpm',
      description: 'science-locus builds with pnpm, not npm',
      type: 'convention',
      scope: '~/Projects/science-locus',
      verified: '2026-08-17',
    })
  })

  it('is nothing at all for a file with no block', () => {
    expect(parseFrontMatter('# Just a heading\n\nand a line.')).toEqual({})
  })

  it('keeps what it read from a block nobody closed', () => {
    // A file the copilot is midway through writing. Half an answer beats none.
    expect(parseFrontMatter('---\ntype: decision\n')).toEqual({ type: 'decision' })
  })
})

describe('the memory listing', () => {
  it('says the folder is absent before the copilot has ever been started', () => {
    const report = readMemory(copilotPaths(dir))
    expect(report.exists).toBe(false)
    expect(report.facts).toEqual([])
    // Absent is not an error. A pane that printed a red line here would be
    // reporting a fault for an app that has simply never been asked to start.
    expect(report.error).toBeNull()
  })

  it('lists the index and the facts, newest first, with their front matter', () => {
    const paths = copilotPaths(dir)
    scaffoldCopilotHome(paths)
    writeFileSync(
      join(paths.memory, 'uses_pnpm.md'),
      '---\ndescription: "builds with pnpm"\ntype: convention\nscope: global\nverified: 2026-08-17\n---\n\nbody\n',
    )
    // Made distinctly older, so "newest first" is an assertion rather than a
    // coincidence of two files written in the same millisecond.
    const older = join(paths.memory, 'no_redis.md')
    writeFileSync(older, '---\ndescription: "decided against Redis"\ntype: decision\n---\n')
    const past = new Date(Date.now() - 60_000)
    utimesSync(older, past, past)

    const report = readMemory(paths)
    expect(report.exists).toBe(true)
    expect(report.facts.map((fact) => fact.name)).toEqual(['uses_pnpm.md', 'MEMORY.md', 'no_redis.md'])

    const first = report.facts[0]
    expect(first.description).toBe('builds with pnpm')
    expect(first.type).toBe('convention')
    expect(first.verified).toBe('2026-08-17')
    expect(first.index).toBe(false)
    expect(report.facts.find((fact) => fact.name === 'MEMORY.md')?.index).toBe(true)
  })
})

describe('a memory name cannot leave the memory folder', () => {
  it('accepts the names the copilot is told to write', () => {
    expect(isMemoryName('science_locus_uses_pnpm.md')).toBe(true)
    expect(isMemoryName('MEMORY.md')).toBe(true)
    expect(isMemoryName('no-redis-2026.md')).toBe(true)
  })

  it('refuses anything that could name another file', () => {
    for (const bad of [
      '../CLAUDE.md',
      '..%2fCLAUDE.md',
      'sub/dir.md',
      '/etc/passwd',
      'C:\\Windows\\win.ini',
      '.md',
      'notes.txt',
      'a\0.md',
      '',
      42,
      null,
    ]) {
      expect(isMemoryName(bad as unknown), String(bad)).toBe(false)
    }
  })

  it('refuses to read or delete through a name it rejected', () => {
    const paths = copilotPaths(dir)
    scaffoldCopilotHome(paths)
    const read = readMemoryFact(paths, '../CLAUDE.md')
    expect(read.ok).toBe(false)
    const removed = deleteMemoryFact(paths, '../CLAUDE.md')
    expect(removed.ok).toBe(false)
    // And the file it was aiming at is still there, which is the thing that
    // actually matters — a refusal that still deleted would pass the line above.
    expect(readMemoryFact(paths, 'MEMORY.md').ok).toBe(true)
    expect(readActionLog(paths).rows.some((row) => row.action === 'memory.deleted')).toBe(false)
  })
})

describe('reading and forgetting one fact', () => {
  it('hands back the whole file, and says when it did not', () => {
    const paths = copilotPaths(dir)
    scaffoldCopilotHome(paths)
    writeFileSync(join(paths.memory, 'small.md'), 'a fact')
    const small = readMemoryFact(paths, 'small.md')
    expect(small).toMatchObject({ ok: true, text: 'a fact', truncated: false })

    writeFileSync(join(paths.memory, 'huge.md'), 'x'.repeat(MAX_MEMORY_READ_BYTES + 10))
    const huge = readMemoryFact(paths, 'huge.md')
    expect(huge.ok && huge.truncated).toBe(true)
    expect(huge.ok && huge.text.length).toBe(MAX_MEMORY_READ_BYTES)
  })

  it('deletes the file, records who did it, and answers with the new listing', () => {
    const paths = copilotPaths(dir)
    scaffoldCopilotHome(paths)
    writeFileSync(join(paths.memory, 'wrong.md'), 'a fact that stopped being true')

    const result = deleteMemoryFact(paths, 'wrong.md')
    expect(result.ok).toBe(true)
    expect(result.memory.facts.map((fact) => fact.name)).not.toContain('wrong.md')

    /*
     * The row has to name the person, not the copilot.
     *
     * The whole value of this file is that a row means one thing. A deletion
     * recorded with no actor reads, in a list of the copilot's own actions, as
     * the copilot deleting its own memory — which would be the log lying about
     * the one subject it exists to be truthful about.
     */
    const row = readActionLog(paths).rows.find((entry) => entry.action === 'memory.deleted')
    expect(row?.detail).toContain('you deleted')
    expect(row?.tool).toBeNull()
  })

  it('reports a file that is not there rather than claiming a delete', () => {
    const paths = copilotPaths(dir)
    scaffoldCopilotHome(paths)
    const result = deleteMemoryFact(paths, 'never-existed.md')
    expect(result.ok).toBe(false)
    expect(result.error).not.toBeNull()
  })
})

describe('the action log', () => {
  it('is empty and unwritten before anything has happened', () => {
    const report = readActionLog(copilotPaths(dir))
    expect(report.exists).toBe(false)
    expect(report.bytes).toBe(0)
    expect(report.rows).toEqual([])
  })

  it('is reported as living outside the folder the copilot may write to', () => {
    /*
     * The pane prints "the copilot cannot write this file". This is the check
     * behind that sentence. `copilot-log-boundary.test.ts` proves the refusal
     * against a real `sandbox-exec`; this proves the *claim on screen* still
     * describes where the file actually is, which is the half that silently
     * stops being true if somebody moves the path back.
     */
    const paths = copilotPaths(dir)
    const report = readActionLog(paths)
    expect(report.outsideCopilotFolder).toBe(true)
    /*
     * And the check cannot be the naive one, which is why it is spelled out
     * here. `<userData>/copilot-log` *does* begin with `<userData>/copilot`,
     * so a plain `startsWith(root)` answers "inside the copilot's folder" for
     * the very directory that was moved out of it — a false negative that
     * would take the sentence off the pane while the boundary was fine.
     */
    expect(report.dir.startsWith(paths.root)).toBe(true)
    expect(report.dir.startsWith(`${paths.root}/`)).toBe(false)
  })

  it('reads both writers of that file into one shape', () => {
    const paths = copilotPaths(dir)
    scaffoldCopilotHome(paths)
    // The app's own event, as `copilot-home.ts` writes it.
    appendCopilotAction(paths, { action: 'session.started', detail: 'started the copilot' })
    // And a tool call, as `deck-control`'s ActionLog writes it.
    const call = {
      v: 1,
      at: new Date().toISOString(),
      id: 'r1',
      action: 'tool.settings.write',
      detail: 'wrote one setting',
      tool: 'settings.write',
      tier: 'alter',
      args: {},
      outcome: 'ok',
      confirmed: { required: true, granted: true, by: 'window-1', at: Date.now(), reason: null },
      caller: { kind: 'local' },
      ms: 42,
      result: {},
      error: null,
    }
    appendFileSync(paths.actions, `${JSON.stringify(call)}\n`)

    const rows = readActionLog(paths).rows
    const event = rows.find((row) => row.action === 'session.started')
    expect(event?.tool).toBeNull()
    expect(event?.confirmed).toBeNull()

    const tool = rows.find((row) => row.action === 'tool.settings.write')
    expect(tool).toMatchObject({
      tool: 'settings.write',
      tier: 'alter',
      outcome: 'ok',
      confirmationRequired: true,
      confirmed: true,
      confirmedBy: 'window-1',
      caller: 'local',
      ms: 42,
    })
  })

  it('skips a torn line instead of showing nothing', () => {
    const paths = copilotPaths(dir)
    mkdirSync(paths.log, { recursive: true })
    writeFileSync(
      paths.actions,
      `{"at":"2026-08-17T00:00:00.000Z","action":"home.created","detail":"made it"}\n{"at":"2026-08-1\n`,
    )
    const rows = readActionLog(paths).rows
    expect(rows).toHaveLength(1)
    expect(rows[0].action).toBe('home.created')
  })

  it('walks back into the rolled generation when the live file is short', () => {
    const paths = copilotPaths(dir)
    mkdirSync(paths.log, { recursive: true })
    writeFileSync(
      `${paths.actions}.1`,
      `{"at":"2026-08-16T00:00:00.000Z","action":"home.created","detail":"yesterday"}\n`,
    )
    writeFileSync(
      paths.actions,
      `{"at":"2026-08-17T00:00:00.000Z","action":"session.started","detail":"today"}\n`,
    )
    const rows = readActionLog(paths, 10).rows
    expect(rows.map((row) => row.detail)).toEqual(['yesterday', 'today'])
  })

  it('says when there is more history than it returned', () => {
    const paths = copilotPaths(dir)
    mkdirSync(paths.log, { recursive: true })
    const lines = Array.from(
      { length: 5 },
      (_, i) => `{"at":"2026-08-17T00:00:0${i}.000Z","action":"tool.x","detail":"${i}"}`,
    )
    writeFileSync(paths.actions, `${lines.join('\n')}\n`)
    const report = readActionLog(paths, 2)
    expect(report.rows.map((row) => row.detail)).toEqual(['3', '4'])
    expect(report.more).toBe(true)
  })
})

describe('one row, parsed', () => {
  it('refuses anything without a time and a name', () => {
    expect(parseActionRow('null')).toBeNull()
    expect(parseActionRow('[]')).toBeNull()
    expect(parseActionRow('{"at":"2026-08-17T00:00:00.000Z"}')).toBeNull()
    expect(parseActionRow('{"action":"tool.x"}')).toBeNull()
  })

  it('reads a refusal with the reason a human never granted it', () => {
    const row = parseActionRow(
      JSON.stringify({
        at: '2026-08-17T00:00:00.000Z',
        action: 'tool.sessions.stop',
        detail: 'refused',
        tool: 'sessions.stop',
        tier: 'alter',
        outcome: 'refused',
        confirmed: {
          required: true,
          granted: false,
          by: null,
          at: null,
          reason: 'not-permitted-unattended',
        },
        error: 'nobody was at the machine',
      }),
    )
    expect(row).toMatchObject({
      outcome: 'refused',
      confirmationRequired: true,
      confirmed: false,
      refusedReason: 'not-permitted-unattended',
      error: 'nobody was at the machine',
    })
  })
})
