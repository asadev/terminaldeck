import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { buildCatalogue, MAX_COPILOT_SESSIONS, type ToolContext, type ToolSpec } from './catalogue'
import { MAX_BRIEF_CHARS, MIN_BRIEF_CHARS, specsDir } from './brief'
import { LOCAL_CALLER, Refused, type DeckSurface } from './surface'
import type { CreateSessionInput, SessionMeta } from '../../shared/types'

/**
 * What `sessions.start` refuses, and why each refusal exists.
 *
 * Every one of these is a rule with a recorded failure behind it rather than a
 * precaution: an agent that wrote into another program's live state directory
 * and corrupted it; two agents in one working tree whose changes could not be
 * told apart afterwards; a parallel-agent count past which the review queue
 * outruns the reviewer and throughput turns into review debt.
 *
 * They are prechecks, so they run *ahead of the budget and ahead of any
 * dialog*. That ordering is the point: a refused start must not consume one of
 * the five starts the copilot is allowed in a window, and a rule that is
 * announced only after somebody has clicked Allow is not a rule.
 */

const START = buildCatalogue().find((tool) => tool.id === 'sessions.start') as ToolSpec

let dir = ''
let state = ''

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-start-'))
  state = join(dir, 'state')
})
afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

interface Rig {
  context: ToolContext
  started: CreateSessionInput[]
  sessions: SessionMeta[]
  copilotOwned: Set<string>
  screen: { value: string | null; onLook: (() => void) | null }
  typed: string[]
}

function rig(options: { projects?: string[]; sessions?: SessionMeta[]; owned?: string[] } = {}): Rig {
  const started: CreateSessionInput[] = []
  const sessions = [...(options.sessions ?? [])]
  const copilotOwned = new Set(options.owned ?? [])
  const screen: { value: string | null; onLook: (() => void) | null } = { value: '❯ ', onLook: null }
  const typed: string[] = []

  const surface = {
    listSessions: () => sessions,
    sessionStatus: () => null,
    startSession: async (input: CreateSessionInput) => {
      started.push(input)
      const meta: SessionMeta = {
        id: `copilot-${started.length}`,
        cwd: input.cwd,
        title: 'work',
        provider: input.provider ?? 'claude',
        exitCode: null,
        createdAt: 5_000,
      }
      sessions.push(meta)
      return meta
    },
    writeToSession: (_id: string, data: string) => {
      typed.push(data)
      /*
       * A terminal echoes what is typed at it, and the delivery protocol waits
       * to *see* that before it presses return — so a fake whose screen never
       * changed would make every delivery time out. `\r` is the commit and
       * clears the line; anything else lands in the composer.
       */
      if (screen.value !== null) {
        screen.value = data === '\r' ? '❯ ' : `❯ ${data.slice(0, 60)}`
      }
    },
    killSession: () => undefined,
    sessionScreen: async () => {
      // A hook rather than a fixed value, so a test can make the session die
      // between two looks — which is what the delivery loop has to notice.
      screen.onLook?.()
      return screen.value
    },
    sessionScrollback: () => screen.value ?? '',
    listProjects: () =>
      (options.projects ?? ['/work/api', '/work/web', join(state, 'copilot')]).map((path) => ({
        path,
        lastOpenedAt: 1,
      })),
    appStateRoot: () => state,
    copilotRoot: () => join(state, 'copilot'),
    gitStatus: async () => ({}),
    alerts: async () => ({}),
    readSettings: () => ({ settings: {}, preferences: {} }),
    writeSettings: (patch: Record<string, unknown>) => patch as Record<string, string | number | boolean>,
    writePreferences: (patch: Record<string, unknown>) => patch,
    snapshotSettings: () => ({ path: '/tmp/x.json', at: 1 }),
    transcriptsIn: async () => [],
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
    readToolTrail: async () => ({ events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({
      repo: false,
      root: null,
      branch: null,
      ahead: 0,
      behind: 0,
      files: [],
      reason: 'no repo',
    }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
  } satisfies DeckSurface

  return {
    started,
    sessions,
    copilotOwned,
    screen,
    typed,
    context: {
      surface,
      callId: 'row-1',
      // Somebody is at the keyboard. Only `tour.play` reads this, and these
      // tests are about what a *start* refuses — but the field is required, so
      // a fixture that left it out would be claiming an unattended run.
      attended: true,
      // The person at this keyboard. Remote callers are `remote/`'s subject;
      // these tests are about what a start refuses, which is the same for both.
      caller: LOCAL_CALLER,
      startedByCopilot: (id) => copilotOwned.has(id),
      noteStarted: (id) => copilotOwned.add(id),
      now: () => Date.parse('2026-08-17T09:42:00'),
    },
  }
}

function live(id: string, cwd: string): SessionMeta {
  return { id, cwd, title: cwd, provider: 'claude', exitCode: null, createdAt: 1_000 }
}

describe('what sessions.start refuses', () => {
  it('will not start a session inside this app’s own storage', () => {
    const built = rig()
    expect(() => START.precheck?.({ cwd: join(state, 'copilot') }, built.context)).toThrow(Refused)
    try {
      START.precheck?.({ cwd: join(state, 'copilot') }, built.context)
    } catch (error) {
      expect((error as Refused).reason).toBe('not-permitted')
      expect((error as Refused).message).toMatch(/own storage/)
    }
  })

  it('refuses a second copilot-started session in the same working tree', () => {
    const built = rig({ sessions: [live('mine-1', '/work/api')], owned: ['mine-1'] })
    expect(() => START.precheck?.({ cwd: '/work/api' }, built.context)).toThrow(/one working tree/)
    // A different folder is fine: the rule is about the tree, not about a count.
    expect(() => START.precheck?.({ cwd: '/work/web' }, built.context)).not.toThrow()
  })

  /**
   * The person's own sessions are not the copilot's to veto.
   *
   * Refusing because somebody had a terminal open in their own repository would
   * be the app telling them how to use their machine, and the collision this
   * rule protects against is between two *agents*, not between an agent and a
   * human who is presumably watching.
   */
  it('says nothing about a session the person started in that folder', () => {
    const built = rig({ sessions: [live('theirs', '/work/api')] })
    expect(() => START.precheck?.({ cwd: '/work/api' }, built.context)).not.toThrow()
  })

  it('caps how many it may have running at once', () => {
    const many = Array.from({ length: MAX_COPILOT_SESSIONS }, (_unused, index) =>
      live(`c${index}`, `/work/${index}`),
    )
    const built = rig({
      projects: ['/work/api', ...many.map((session) => session.cwd)],
      sessions: many,
      owned: many.map((session) => session.id),
    })
    expect(() => START.precheck?.({ cwd: '/work/api' }, built.context)).toThrow(/is the limit/)
  })

  it('does not count sessions that have already exited towards the cap', () => {
    const dead = Array.from({ length: MAX_COPILOT_SESSIONS }, (_unused, index) => ({
      ...live(`c${index}`, `/work/${index}`),
      exitCode: 0,
    }))
    const built = rig({
      projects: ['/work/api', ...dead.map((session) => session.cwd)],
      sessions: dead,
      owned: dead.map((session) => session.id),
    })
    expect(() => START.precheck?.({ cwd: '/work/api' }, built.context)).not.toThrow()
  })

  it('refuses a brief too short to be one, and one too long to be an instruction', () => {
    const built = rig()
    expect(() =>
      START.precheck?.({ cwd: '/work/api', brief: 'fix it', title: 'fix' }, built.context),
    ).toThrow(new RegExp(`at least ${MIN_BRIEF_CHARS} characters`))
    expect(() =>
      START.precheck?.(
        { cwd: '/work/api', brief: 'x'.repeat(MAX_BRIEF_CHARS + 1), title: 'fix' },
        built.context,
      ),
    ).toThrow(/Scope the work/)
  })

  it('insists a brief is named, because the name becomes its filename', () => {
    const built = rig()
    expect(() =>
      START.precheck?.({ cwd: '/work/api', brief: 'x'.repeat(MIN_BRIEF_CHARS + 1) }, built.context),
    ).toThrow(/needs a `title`/)
  })
})

describe('starting with a brief', () => {
  const brief =
    'Base branch is main. Fix auth.test.ts, which is flaky because of the clock. ' +
    'Done means it passes ten runs in a row. Do not touch the fixtures.'

  it('writes the spec, then points the session at it', async () => {
    const built = rig()
    const output = await START.run(
      { cwd: '/work/api', brief, title: 'Fix the flaky auth test' },
      built.context,
    )
    const value = output.value as { spec: { path: string; delivered: boolean } }

    expect(value.spec.delivered).toBe(true)
    expect(readdirSync(specsDir(join(state, 'copilot')))).toHaveLength(1)
    expect(readFileSync(value.spec.path, 'utf8')).toContain('Do not touch the fixtures.')
    /*
     * One line naming the file, then the return as its own write.
     *
     * Not the brief itself: a multi-paragraph brief typed into a composer
     * arrives as several half-messages, because newline is submit. And not
     * `line + '\r'` in one write either — that is a paste, and a newline inside
     * a paste is a newline. `brief.ts` has the account.
     */
    expect(built.typed).toHaveLength(2)
    expect(built.typed[0]).toContain(value.spec.path)
    expect(built.typed[1]).toBe('\r')
  })

  /**
   * The failure that would otherwise be silent, and the reason this whole
   * delivery step is worth its complexity.
   *
   * A session that started and never received its brief is an agent running in
   * somebody's repository, billing, with no idea what it is for. The spec still
   * exists on disk, so the situation is recoverable — and the result says so in
   * a sentence rather than leaving the model to notice a false boolean.
   */
  it('keeps the spec and says what to do when the brief could not be delivered', async () => {
    const built = rig()
    built.screen.value = null
    // The CLI died on startup — a missing binary, a failed login, a crash. The
    // real clock is left alone here on purpose: `brief.test.ts` drives the
    // twenty-second timeout with a fake one, and a test that genuinely waits
    // twenty seconds is a test somebody will delete.
    built.screen.onLook = () => {
      const created = built.sessions.at(-1)
      if (created) created.exitCode = 1
    }
    const output = await START.run(
      { cwd: '/work/api', brief, title: 'Fix the flaky auth test' },
      built.context,
    )
    const value = output.value as { spec: { path: string; delivered: boolean; nextStep: string } }

    expect(value.spec.delivered).toBe(false)
    expect(built.typed).toEqual([])
    expect(readFileSync(value.spec.path, 'utf8')).toContain('Base branch is main.')
    expect(value.spec.nextStep).toMatch(/sessions\.send/)
  })

  /**
   * The brief reaches disk before a process reaches the machine.
   *
   * This ran the other way round — start, then write, then deliver — and the
   * failure hiding in that order costs money silently: if the write throws
   * (specs directory unwritable, disk full, a title the filesystem refuses) the
   * call fails *after* an agent is already running, with no brief, no file to
   * recover from, and nothing in the result to say a session exists at all. The
   * person is left with a tab billing for nothing.
   *
   * Written first, that becomes a refusal with nothing started and nothing
   * spent — which is what this asserts, by making the write fail the only way a
   * test can make it fail for real: a specs directory that cannot be created
   * because a file is sitting where it must go.
   */
  it('refuses without starting anything when the brief cannot be written', async () => {
    const built = rig()
    // `specsDir` is `<copilotRoot>/specs`. A regular file there makes `mkdirSync`
    // throw ENOTDIR — a real filesystem refusal rather than a stubbed one.
    mkdirSync(join(state, 'copilot'), { recursive: true })
    writeFileSync(specsDir(join(state, 'copilot')), 'not a directory', 'utf8')

    await expect(
      START.run({ cwd: '/work/api', brief, title: 'Fix the flaky auth test' }, built.context),
    ).rejects.toThrow()

    // The whole point: no session, no spend, nothing typed at anything.
    expect(built.started).toEqual([])
    expect(built.sessions).toEqual([])
    expect(built.typed).toEqual([])
  })

  it('starts without a brief when there is nothing to scope', async () => {
    const built = rig()
    const output = await START.run({ cwd: '/work/api', provider: 'shell' }, built.context)
    expect((output.value as { spec: null }).spec).toBeNull()
    expect(built.typed).toEqual([])
  })
})
