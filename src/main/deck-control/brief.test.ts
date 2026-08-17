import { mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  DELIVERY_TIMEOUT_MS,
  deliverBrief,
  deliveryLine,
  slugifyTitle,
  specsDir,
  stampOf,
  writeSpec,
  type DeliveryClock,
} from './brief'
import type { SessionMeta } from '../../shared/types'

/**
 * The brief, and the promise that a session never runs with instructions
 * nobody knows it did not receive.
 *
 * Half of this file is about the failure path, and that is proportionate. A
 * brief that lands is unremarkable; a brief that quietly does not land leaves
 * an agent running in somebody's repository, billing, with no idea what it is
 * for — so every way the delivery can fail has to come back as a stated reason
 * rather than as a boolean nobody reads.
 */

let dir = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-brief-'))
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

describe('writing the spec', () => {
  it('records the three facts that make a brief re-runnable', () => {
    const spec = writeSpec(specsDir(dir), {
      title: 'Fix the flaky auth test',
      brief: 'Base branch is main. The test is auth.test.ts. Done means it passes ten times.',
      cwd: '/work/api',
      provider: 'claude',
      callId: 'row-7',
      at: Date.parse('2026-08-17T09:42:00'),
    })
    const text = readFileSync(spec.path, 'utf8')
    // Repo, agent and the turn that produced it. Without the repo the file
    // cannot be re-run anywhere else, which is most of why it is a file.
    expect(text).toContain('repo: /work/api')
    expect(text).toContain('agent: claude')
    expect(text).toContain('from-turn: row-7')
    expect(text).toContain('Base branch is main.')
  })

  it('names the file so a person can find today’s briefs by eye', () => {
    const at = Date.parse('2026-08-17T09:42:00')
    const spec = writeSpec(specsDir(dir), {
      title: 'Fix the flaky auth test',
      brief: 'x',
      cwd: '/work/api',
      provider: null,
      callId: 'row-1',
      at,
    })
    expect(spec.slug).toBe(`${stampOf(at)}-fix-the-flaky-auth-test`)
    expect(readdirSync(specsDir(dir))).toEqual([`${spec.slug}.md`])
  })

  it('refuses to let a title become a path', () => {
    // The string is concatenated into a filename, so everything that is not a
    // lowercase letter, a digit or a hyphen has to stop being one.
    expect(slugifyTitle('../../etc/passwd')).toBe('etc-passwd')
    expect(slugifyTitle('  ')).toBe('brief')
    expect(slugifyTitle('A/B  test — round 2!')).toBe('a-b-test-round-2')
  })
})

describe('delivering the brief', () => {
  function fakeClock(): DeliveryClock & { advance: number } {
    const state = { now: 0, advance: 0 }
    return {
      get advance() {
        return state.advance
      },
      now: () => state.now,
      sleep: async (ms: number) => {
        state.now += ms
        state.advance += ms
      },
    }
  }

  function session(over: Partial<SessionMeta> = {}): SessionMeta {
    return {
      id: 'new-1',
      cwd: '/work/api',
      title: 'api',
      provider: 'claude',
      exitCode: null,
      createdAt: 0,
      ...over,
    }
  }

  /**
   * The return is a *separate write*, and this is the assertion that keeps it
   * that way.
   *
   * Appending it — `write(`${line}\r`)` — is one call, is obviously right, and
   * does not work: a 271-character burst is a paste, and the CLI treats a
   * newline inside a paste as a newline. Seen on a real session, with the brief
   * sitting unsent in the composer while everything upstream reported success.
   */
  it('types the brief, waits for it to appear, and only then presses return', async () => {
    const typed: Array<{ id: string; data: string }> = []
    const line = deliveryLine('/spec.md')
    let looks = 0
    const result = await deliverBrief(
      {
        listSessions: () => [session()],
        sessionScreen: async () => {
          looks += 1
          // Two frames of a CLI still starting, then an empty composer, then
          // the composer echoing back the first wrapped row of the brief.
          if (looks < 3) return '✶ Galloping…'
          if (looks === 3) return '❯ '
          return `❯ ${line.slice(0, 60)}`
        },
        writeToSession: (id, data) => {
          typed.push({ id, data })
        },
      },
      'new-1',
      line,
      { clock: fakeClock() },
    )

    expect(result.delivered).toBe(true)
    expect(typed.map((entry) => entry.data)).toEqual([line, '\r'])
  })

  it('clears the line rather than pressing return at text it never saw land', async () => {
    const typed: string[] = []
    const result = await deliverBrief(
      {
        listSessions: () => [session()],
        // Ready, and then the typing never shows up: the keystrokes went
        // somewhere this app cannot see.
        sessionScreen: async () => '❯ ',
        writeToSession: (_id, data) => {
          typed.push(data)
        },
      },
      'new-1',
      'go somewhere',
      { clock: fakeClock(), pollMs: 500 },
    )

    expect(result.delivered).toBe(false)
    expect(result.reason).toMatch(/never appeared on the session command line/)
    // Never a bare return. The rollback is Ctrl-U, and it is safe because the
    // composer was seen empty before anything was typed.
    expect(typed).toEqual(['go somewhere', '\x15'])
  })

  it('never types into a composer that already has something in it', async () => {
    const typed: string[] = []
    const clock = fakeClock()
    const result = await deliverBrief(
      {
        listSessions: () => [session()],
        // A half-written sentence at the prompt. Typing now would run into the
        // middle of it — `refuseToType` is the accumulated knowledge of that.
        sessionScreen: async () => '❯ remind me to buy milk',
        writeToSession: (_id, data) => {
          typed.push(data)
        },
      },
      'new-1',
      'go',
      { clock, timeoutMs: 2_000, pollMs: 500 },
    )

    expect(typed).toEqual([])
    expect(result.delivered).toBe(false)
    // The refusal's own sentence, not "timed out": it says *why* typing would
    // have been wrong, which is what a person needs.
    expect(result.reason).toMatch(/unsent text/)
  })

  it('gives up with a reason rather than waiting forever', async () => {
    const clock = fakeClock()
    const result = await deliverBrief(
      {
        listSessions: () => [session()],
        sessionScreen: async () => null,
        writeToSession: () => undefined,
      },
      'new-1',
      'go',
      { clock, pollMs: 1_000 },
    )
    expect(result.delivered).toBe(false)
    expect(result.reason).toMatch(/never drew a prompt/)
    expect(result.waitedMs).toBeGreaterThanOrEqual(DELIVERY_TIMEOUT_MS)
  })

  it('stops the moment the session dies', async () => {
    const result = await deliverBrief(
      {
        listSessions: () => [session({ exitCode: 1 })],
        sessionScreen: async () => '❯ ',
        writeToSession: () => undefined,
      },
      'new-1',
      'go',
      { clock: fakeClock() },
    )
    expect(result.delivered).toBe(false)
    expect(result.reason).toMatch(/ended before/)
  })

  it('tells the session the file is the whole of what it was asked', async () => {
    // The alternative reading — that this line is a preamble to instructions
    // still to come — produces a session sitting waiting for a second message
    // nobody is going to send.
    const line = deliveryLine('/specs/x.md')
    expect(line).toContain('/specs/x.md')
    expect(line).toMatch(/whole brief/)
    expect(line).toMatch(/Read it before you start/)
  })
})
