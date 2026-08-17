import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { ActionLog, type ActionRow } from './action-log'
import { DEFAULT_TRANSCRIPT_LIMIT, MAX_TRANSCRIPT_CHARS } from './catalogue'
import { ConsentBroker, type ConsentRequest } from './consent'
import { DeckControl } from './control'
import type { DeckSurface, TranscriptMessage } from './surface'
import type { CreateSessionInput, SessionMeta, SessionStatus } from '../../shared/types'

/**
 * The dispatcher, which is where "may this happen" is decided.
 *
 * The surface is a fake here on purpose. `live-surface.test.ts` proves the real
 * one talks to the real modules; this file proves the rules, and a rule about
 * refusing to write a setting is easiest to trust when the test can see that
 * the setting was not written.
 *
 * The load-bearing test in this file is
 * "refuses an alter call when there is nobody to confirm it, and changes
 * nothing". If a future change made the gate open by default, that is the
 * assertion that would go red.
 */

/* ------------------------------------------------------------------- fake -- */

interface Recorder {
  surface: DeckSurface
  typed: Array<{ id: string; data: string }>
  killed: string[]
  started: CreateSessionInput[]
  settings: Record<string, string | number | boolean>
  preferences: Record<string, unknown>
  sessions: SessionMeta[]
  statuses: Map<string, { status: SessionStatus; at: number }>
  transcript: TranscriptMessage[]
  transcriptSize: number
  reads: Array<{ path: string; from: number }>
  /**
   * Every event that changes settings, in the order it happened.
   *
   * A list rather than counters, because the assertion that matters about
   * `settings.write` is an *ordering* one — the snapshot happens before the
   * person is asked, and the write after — and counters cannot express it.
   */
  settingsTrace: string[]
  /** Set to make the snapshot fail, the way a full disk would. */
  snapshotFails: boolean
  /**
   * The folders each paired device may start a session in.
   *
   * The rule `sessions.start` narrows itself against for a remote caller. Held
   * as state rather than as a constant so a test can take a folder away and
   * watch the very next call be refused, which is the whole property of the
   * grant being read per call.
   */
  deviceFolders: Map<string, string[]>
  /** `(deviceId, cwd)` for every start, so the guest path can be pinned. */
  startedFor: Array<{ deviceId: string | undefined; cwd: string }>
}

function meta(overrides: Partial<SessionMeta> & { id: string }): SessionMeta {
  return {
    cwd: '/work/api',
    title: 'api',
    provider: 'claude',
    exitCode: null,
    createdAt: 1_000,
    ...overrides,
  }
}

function fakeSurface(): Recorder {
  const state: Recorder = {
    surface: {} as DeckSurface,
    typed: [],
    killed: [],
    started: [],
    settings: { 'appearance.density': 'comfortable' },
    preferences: { theme: 'dark', defaultProvider: 'claude', restoreSessions: true, notifyOnComplete: true },
    sessions: [meta({ id: 'human-1' }), meta({ id: 'human-2', cwd: '/work/web', title: 'web' })],
    statuses: new Map([['human-1', { status: 'working' as SessionStatus, at: 2_000 }]]),
    transcript: [],
    transcriptSize: 0,
    reads: [],
    settingsTrace: [],
    snapshotFails: false,
    deviceFolders: new Map([['phone-1', ['/work/api']]]),
    startedFor: [],
  }

  state.surface = {
    listSessions: () => state.sessions,
    sessionStatus: (id) => state.statuses.get(id) ?? null,
    startSession: async (input, forDevice) => {
      state.started.push(input)
      // Recorded separately from `input`, because it is not part of the input:
      // it is who asked, and it is what decides whether the session gets a guest
      // git identity and a boundary. A start that lost it would look identical
      // here and be a session running with the owner's credentials.
      state.startedFor.push({ deviceId: forDevice, cwd: input.cwd })
      const created = meta({ id: `copilot-${state.started.length}`, cwd: input.cwd })
      state.sessions = [...state.sessions, created]
      return created
    },
    deviceFolders: (deviceId) => state.deviceFolders.get(deviceId) ?? [],
    writeToSession: (id, data) => {
      state.typed.push({ id, data })
    },
    killSession: (id) => {
      state.killed.push(id)
      state.sessions = state.sessions.filter((session) => session.id !== id)
    },
    sessionScreen: async () => 'the last screen\nof a shell',
    sessionScrollback: () => 'the last screen\nof a shell',
    listProjects: () => [
      { path: '/work/api', lastOpenedAt: 3 },
      { path: '/work/web', lastOpenedAt: 2 },
      // A third, so the budget tests can start three sessions without tripping
      // the one-copilot-session-per-working-tree rule first.
      { path: '/work/docs', lastOpenedAt: 1 },
    ],
    gitStatus: async (cwd) => ({ repo: true, cwd, clean: true }),
    alerts: async (projectPath) => ({ projectPath, alerts: [{ id: 'a' }] }),
    readSettings: () => ({ settings: { ...state.settings }, preferences: { ...state.preferences } }),
    snapshotSettings: () => {
      state.settingsTrace.push('snapshot')
      if (state.snapshotFails) throw new Error('read-only file system')
      return { path: '/tmp/settings.last-good.json', at: 7 }
    },
    writeSettings: (patch) => {
      state.settingsTrace.push('write')
      for (const [key, value] of Object.entries(patch)) {
        if (value === null) delete state.settings[key]
        else if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
          state.settings[key] = value
        }
      }
      return { ...state.settings }
    },
    writePreferences: (patch) => {
      state.settingsTrace.push('write')
      state.preferences = { ...state.preferences, ...patch }
      return { ...state.preferences }
    },
    transcriptsIn: async (cwd) =>
      cwd === '/work/api'
        ? [
            {
              path: '/transcripts/api.jsonl',
              sessionId: 'api',
              createdAt: 1_000,
              modifiedAt: 2_000,
              bytes: 512,
            },
          ]
        : [],
    transcriptBytes: async () => state.transcriptSize,
    readTranscriptFrom: async (path, from) => {
      state.reads.push({ path, from })
      return state.transcript
    },
    /*
     * The five reads the fleet capabilities added, answered inertly.
     *
     * This fake exists to exercise the dispatcher, not the reports, so every
     * one of these returns the empty answer its real counterpart returns for a
     * folder with no repository and a session with no transcript. The report
     * tools have their own tests with their own fixtures.
     */
    readToolTrail: async () => ({ events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({
      repo: false,
      root: null,
      branch: null,
      ahead: 0,
      behind: 0,
      files: [],
      reason: 'not a repository',
    }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
    // `<userData>` and the copilot's folder inside it. Distinct from every
    // project path in these fixtures, which is what `sessions.start`'s refusal
    // to run inside the app's own storage needs in order to mean anything.
    appStateRoot: () => '/state',
    copilotRoot: () => '/state/copilot',
  }
  return state
}

/* ------------------------------------------------------------------- rig -- */

let dir = ''
let asked: ConsentRequest[] = []
/** What the fake approver does next. `null` means there is no approver at all. */
let answer: boolean | null = null

function build(options: { budgets?: ConstructorParameters<typeof DeckControl>[0]['budgets'] } = {}): {
  control: DeckControl
  state: Recorder
  log: ActionLog
} {
  const state = fakeSurface()
  const log = new ActionLog({ dir })
  const consent = new ConsentBroker({
    ask: (request) => {
      // Traced even when there is no approver: "was a person asked" and "was a
      // person available" are different facts, and an ordering assertion needs
      // the first one.
      state.settingsTrace.push('asked')
      if (answer === null) return false
      asked.push(request)
      // Answered on the next turn of the loop, the way a real window would —
      // synchronously would hide any ordering bug between delivery and the
      // pending map.
      const decision = answer
      queueMicrotask(() => consent.respond(request.id, decision, 'window'))
      return true
    },
    timeoutMs: 25,
  })
  const control = new DeckControl({
    surface: state.surface,
    log,
    consent,
    ...(options.budgets === undefined ? {} : { budgets: options.budgets }),
  })
  return { control, state, log }
}

function rows(): ActionRow[] {
  const file = join(dir, 'actions.jsonl')
  try {
    return readFileSync(file, 'utf8')
      .split('\n')
      .filter((line) => line.length > 0)
      .map((line) => JSON.parse(line) as ActionRow)
  } catch {
    return []
  }
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'deck-control-test-'))
  asked = []
  answer = null
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

/* ------------------------------------------------------------------ tests -- */

describe('reads are always allowed', () => {
  it('lists sessions with their live status', async () => {
    const { control } = build()
    const result = await control.call('sessions_list', {})

    expect(result.ok).toBe(true)
    const value = result.value as { sessions: Array<{ id: string; status: string }> }
    const byId = new Map(value.sessions.map((session) => [session.id, session.status]))
    expect([...byId.keys()].sort()).toEqual(['human-1', 'human-2'])
    expect(byId.get('human-1')).toBe('working')
    // Nothing has classified `human-2`; `idle` is the honest default rather
    // than inheriting its neighbour's status.
    expect(byId.get('human-2')).toBe('idle')
  })

  it('puts the sessions that need somebody first, not the ones that started first', async () => {
    /*
     * Triage order, and the case that makes it worth having: the *newest*
     * session is the blocked one, so creation order and attention order
     * disagree. A model reading a list has to hold all of it to find the
     * blocked one unless the list answers the question in its first row.
     */
    const { control, state } = build()
    state.sessions = [
      meta({ id: 'busy' }),
      meta({ id: 'quiet-one' }),
      meta({ id: 'blocked' }),
    ]
    state.statuses = new Map([
      ['busy', { status: 'working', at: 1 }],
      ['quiet-one', { status: 'waiting', at: 1 }],
      ['blocked', { status: 'input', at: 1 }],
    ])

    const value = (await control.call('sessions_list', {})).value as {
      sessions: Array<{ id: string; attention: string; attentionReason: string }>
      blocked: number
    }
    expect(value.sessions.map((session) => session.id)).toEqual(['blocked', 'quiet-one', 'busy'])
    expect(value.blocked).toBe(1)
    // The subtlety this field exists for: `waiting` is an empty prompt, which
    // needs nobody. If it ever reads as `blocked`, fleet triage is noise.
    expect(value.sessions[1]).toMatchObject({ attention: 'quiet', attentionReason: 'prompt-ready' })
    expect(value.sessions[0]).toMatchObject({ attention: 'blocked', attentionReason: 'question-unanswered' })
  })

  it('says how long the blocked one has been blocked, on the dispatcher’s clock', async () => {
    const state = fakeSurface()
    const log = new ActionLog({ dir })
    const consent = new ConsentBroker({ ask: () => false })
    // A frozen clock, so the number in the result is a fact rather than a
    // race against the test runner.
    const control = new DeckControl({ surface: state.surface, log, consent, now: () => 1_000_000 })
    state.sessions = [meta({ id: 'blocked' })]
    state.statuses = new Map([['blocked', { status: 'input', at: 400_000 }]])

    const value = (await control.call('sessions_list', {})).value as {
      sessions: Array<{ attentionForMs: number; statusSource: string }>
    }
    expect(value.sessions[0].attentionForMs).toBe(600_000)
    expect(value.sessions[0].statusSource).toBe('screen')
  })

  it('reports an exited session as exited whatever the tracker last said', async () => {
    const { control, state } = build()
    state.sessions = [meta({ id: 'human-1', exitCode: 0 })]
    state.statuses.set('human-1', { status: 'working', at: 5 })

    const value = (await control.call('sessions_list', {})).value as {
      sessions: Array<{ status: string }>
    }
    expect(value.sessions[0].status).toBe('exited')
  })

  it('will not say how long ago a session ended, because nothing records that', async () => {
    /*
     * The real shape: `onExit` in `src/main/index.ts` deletes the live-status
     * entry, so an exited session has none. Reporting `now - createdAt` would
     * describe a session that died a minute ago as having been finished for as
     * long as it ran.
     */
    const { control, state } = build()
    state.sessions = [meta({ id: 'human-1', exitCode: 0, createdAt: 1 })]
    state.statuses.delete('human-1')

    const value = (await control.call('sessions_list', {})).value as {
      sessions: Array<{ attention: string; attentionForMs: number | null }>
    }
    expect(value.sessions[0].attention).toBe('done')
    expect(value.sessions[0].attentionForMs).toBeNull()
  })

  it('answers with the dotted id as well as the wire name', async () => {
    const { control } = build()
    // The log and the design document use dots; a routine file or a hand
    // written call should not have to know which spelling it is holding.
    expect((await control.call('sessions.list', {})).ok).toBe(true)
  })

  it('needs no confirmation, and says so in the log', async () => {
    const { control } = build()
    await control.call('projects_list', {})

    const [row] = rows()
    expect(row.tool).toBe('projects.list')
    expect(row.tier).toBe('read')
    expect(row.confirmed).toEqual({ required: false, granted: false, by: null, at: null, reason: null })
  })
})

describe('folders the copilot may name', () => {
  it('answers about a project this app has open', async () => {
    const { control } = build()
    expect((await control.call('git_status', { cwd: '/work/api' })).ok).toBe(true)
  })

  it('refuses a folder it was not given', async () => {
    const { control } = build()
    const result = await control.call('git_status', { cwd: '/etc' })

    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-permitted')
    expect(result.error).toContain('projects.list')
    expect(rows()[0].outcome).toBe('refused')
  })

  it('counts the folder of a live session, not only a saved project', async () => {
    const { control, state } = build()
    state.sessions = [meta({ id: 'x', cwd: '/somewhere/else' })]
    expect((await control.call('alerts_list', { projectPath: '/somewhere/else' })).ok).toBe(true)
  })
})

describe('starting a session', () => {
  it('runs without a confirmation and is recorded', async () => {
    const { control, state } = build()
    const result = await control.call('sessions_start', { cwd: '/work/api', provider: 'claude' })

    expect(result.ok).toBe(true)
    expect(state.started).toEqual([
      {
        cwd: '/work/api',
        cols: 120,
        rows: 30,
        resume: false,
        provider: 'claude',
        // Who wanted it, and which turn asked. Both are labels and neither is a
        // permission — see `session-provenance.test.ts`, which is where the two
        // are actually pinned; they are spelled out here because this assertion
        // is exact, and an exact one that quietly stopped covering two fields
        // would be the wrong kind of green.
        origin: 'copilot',
        originRunId: result.row.id,
      },
    ])
    expect(asked).toEqual([])
    expect(rows()[0]).toMatchObject({ tier: 'act', outcome: 'ok', action: 'tool.sessions.start' })
  })

  it('refuses a folder this app does not have open', async () => {
    const { control, state } = build()
    const result = await control.call('sessions_start', { cwd: '/tmp/anything' })

    expect(result.refusal).toBe('not-permitted')
    expect(state.started).toEqual([])
  })

  it('refuses a provider that is not one of ours', async () => {
    const { control, state } = build()
    expect((await control.call('sessions_start', { cwd: '/work/api', provider: 'gpt' })).ok).toBe(false)
    expect(state.started).toEqual([])
  })

  it('is capped, because every one of them costs money', async () => {
    const { control, state } = build({
      budgets: { sessionStarts: { limit: 2, windowMs: 60_000 } },
    })
    // Three different folders, because one copilot-started session per working
    // tree is now its own rule — see `refuseSecondSessionHere`. This test is
    // about the *budget*, so it must not trip the other guard first.
    await control.call('sessions_start', { cwd: '/work/api' })
    await control.call('sessions_start', { cwd: '/work/web' })
    const third = await control.call('sessions_start', { cwd: '/work/docs' })

    expect(third.refusal).toBe('rate-limited')
    expect(state.started).toHaveLength(2)
  })
})

describe('typing into a session', () => {
  it('types into a session the copilot started without asking anybody', async () => {
    const { control, state } = build()
    const started = (await control.call('sessions_start', { cwd: '/work/api' })).value as {
      session: { id: string }
    }

    const result = await control.call('sessions_send', { sessionId: started.session.id, text: 'run the tests' })

    expect(result.ok).toBe(true)
    expect(state.typed).toEqual([{ id: started.session.id, data: 'run the tests\r' }])
    expect(asked).toEqual([])
    expect(rows()[1].tier).toBe('act')
  })

  it('will not type into somebody else’s session without their say-so', async () => {
    const { control, state } = build()
    answer = null // no window is listening

    const result = await control.call('sessions_send', { sessionId: 'human-1', text: 'rm -rf everything' })

    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('no-approver')
    // The actual property under test: not a word reached the pty.
    expect(state.typed).toEqual([])

    const [row] = rows()
    expect(row.tier).toBe('alter')
    expect(row.baseTier).toBe('act')
    expect(row.confirmed).toMatchObject({ required: true, granted: false, reason: 'no-approver' })
  })

  it('types into somebody else’s session once they have allowed it', async () => {
    const { control, state } = build()
    answer = true

    const result = await control.call('sessions_send', { sessionId: 'human-1', text: 'status?' })

    expect(result.ok).toBe(true)
    expect(state.typed).toEqual([{ id: 'human-1', data: 'status?\r' }])
    expect(asked[0].summary).toContain('status?')
    expect(rows()[0].confirmed).toMatchObject({ required: true, granted: true, by: 'window' })
  })

  it('does not type when the person says no', async () => {
    const { control, state } = build()
    answer = false

    expect((await control.call('sessions_send', { sessionId: 'human-1', text: 'go' })).refusal).toBe(
      'declined',
    )
    expect(state.typed).toEqual([])
  })

  it('appends exactly one return, and only when asked to submit', async () => {
    const { control, state } = build()
    const started = (await control.call('sessions_start', { cwd: '/work/api' })).value as {
      session: { id: string }
    }
    await control.call('sessions_send', {
      sessionId: started.session.id,
      text: 'half a thought',
      submit: false,
    })
    expect(state.typed[0].data).toBe('half a thought')
  })

  it('refuses control characters before the tier is even relevant', async () => {
    const { control, state } = build()
    const started = (await control.call('sessions_start', { cwd: '/work/api' })).value as {
      session: { id: string }
    }
    const result = await control.call('sessions_send', {
      sessionId: started.session.id,
      text: 'ok\u0003',
    })

    expect(result.ok).toBe(false)
    expect(state.typed).toEqual([])
  })

  it('refuses control characters without drawing a dialog for them first', async () => {
    // Same rule as the protected settings: an argument that can never be
    // allowed must not reach a person as a question. Otherwise the dialog
    // quotes text that is about to be rejected, and the person learns that
    // clicking Allow is harmless.
    const { control, state } = build()
    answer = true

    const result = await control.call('sessions_send', {
      sessionId: 'human-1',
      text: 'ok\u001b]0;pwned\u0007',
    })

    expect(result.ok).toBe(false)
    expect(asked).toEqual([])
    expect(state.typed).toEqual([])
  })

  it('refuses to type into a session that has already exited', async () => {
    const { control, state } = build()
    state.sessions = [meta({ id: 'human-1', exitCode: 1 })]
    answer = true

    expect((await control.call('sessions_send', { sessionId: 'human-1', text: 'hello' })).ok).toBe(false)
    expect(state.typed).toEqual([])
  })

  it('quotes what was typed in the log, so the record is auditable', async () => {
    const { control } = build()
    answer = true
    await control.call('sessions_send', { sessionId: 'human-1', text: 'deploy to production' })

    const [row] = rows()
    expect(row.args).toMatchObject({ sessionId: 'human-1', text: 'deploy to production' })
    expect(row.sessionId).toBe('human-1')
    expect(row.detail).toContain('allowed by the person')
  })
})

describe('stopping a session', () => {
  it('stops its own without asking', async () => {
    const { control, state } = build()
    const started = (await control.call('sessions_start', { cwd: '/work/api' })).value as {
      session: { id: string }
    }
    await control.call('sessions_stop', { sessionId: started.session.id })

    expect(state.killed).toEqual([started.session.id])
    expect(asked).toEqual([])
  })

  it('will not kill somebody else’s work unasked', async () => {
    const { control, state } = build()
    answer = null

    expect((await control.call('sessions_stop', { sessionId: 'human-1' })).refusal).toBe('no-approver')
    expect(state.killed).toEqual([])
  })
})

describe('the settings gate', () => {
  it('refuses an alter call when there is nobody to confirm it, and changes nothing', async () => {
    /*
     * The proof the whole feature rests on.
     *
     * No window has registered as an approver — which is the state the app is
     * in before the copilot's UI exists at all, and the state it returns to
     * every time that window closes. The call must be refused, the refusal must
     * name its reason, and the settings must be exactly as they were.
     */
    const { control, state } = build()
    answer = null

    const result = await control.call('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })

    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('no-approver')
    expect(state.settings['appearance.density']).toBe('comfortable')

    const [row] = rows()
    expect(row.outcome).toBe('refused')
    expect(row.confirmed).toMatchObject({ required: true, granted: false, reason: 'no-approver' })
  })

  it('refuses on a timeout, and changes nothing', async () => {
    const state = fakeSurface()
    const log = new ActionLog({ dir })
    // An approver that takes delivery and never answers — a dialog on a screen
    // nobody is sitting in front of.
    const consent = new ConsentBroker({ ask: () => true, timeoutMs: 5 })
    const control = new DeckControl({ surface: state.surface, log, consent })

    const result = await control.call('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })

    expect(result.refusal).toBe('timeout')
    expect(state.settings['appearance.density']).toBe('comfortable')
  })

  it('writes once the person allows it', async () => {
    const { control, state } = build()
    answer = true

    const result = await control.call('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })

    expect(result.ok).toBe(true)
    expect(state.settings['appearance.density']).toBe('compact')
    expect(asked[0].summary).toBe('Change settings: appearance.density to "compact"')
  })

  it('writes preferences through the preferences scope', async () => {
    const { control, state } = build()
    answer = true

    expect((await control.call('settings_write', { scope: 'preferences', patch: { theme: 'light' } })).ok).toBe(
      true,
    )
    expect(state.preferences.theme).toBe('light')
  })

  it('refuses a preference key that is not one of the four', async () => {
    const { control } = build()
    answer = true
    const result = await control.call('settings_write', {
      scope: 'preferences',
      patch: { windowBounds: { width: 1 } },
    })
    expect(result.refusal).toBe('not-permitted')
  })
})

describe('a way back, and a check, before anybody is asked', () => {
  /**
   * The ordering assertion, and it is the whole of `COPILOT-CAPABILITIES.md`
   * item 6.
   *
   * Validate, snapshot, *then* draw the dialog. Getting this backwards is not a
   * cosmetic fault: a person who confirms a change that then fails has consented
   * to nothing, and has been taught that the dialog does not correspond to an
   * outcome. And a snapshot taken after approval is a snapshot that does not
   * exist for the one write nobody expected.
   */
  it('snapshots the settings before the person is asked, and writes after', async () => {
    const { control, state } = build()
    answer = true

    expect((await control.call('settings_write', { scope: 'settings', patch: { 'appearance.density': 'compact' } })).ok).toBe(
      true,
    )

    // `snapshot` appears twice because `precheck` and `run` each take one — the
    // handler does not trust that it was prechecked. What matters is that the
    // first one is before `asked` and every `write` is after it.
    expect(state.settingsTrace.indexOf('snapshot')).toBeLessThan(state.settingsTrace.indexOf('asked'))
    expect(state.settingsTrace.indexOf('asked')).toBeLessThan(state.settingsTrace.indexOf('write'))
    expect(state.settingsTrace.filter((event) => event === 'write')).toHaveLength(1)
  })

  it('asks about the value that will be written, not the one that was requested', async () => {
    /*
     * The schema clamps a number into range rather than rejecting it — a
     * deliberate choice made where the schema is declared, because a font size
     * of 400 was a real preference typed into a build with a wider range. What
     * must not happen is a person approving "set the font size to 4000" and
     * getting 32: they would have consented to a different change from the one
     * that landed.
     */
    const { control } = build()
    answer = true

    await control.call('settings_write', {
      scope: 'settings',
      patch: { 'appearance.terminalFontSize': 4_000 },
    })

    expect(asked).toHaveLength(1)
    expect(asked[0].summary).toMatch(/appearance\.terminalFontSize to \d+ \(asked for 4000\)/)
  })

  it('tells the copilot where the copy went, so it can tell the person', async () => {
    const { control } = build()
    answer = true
    const result = await control.call('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })
    expect((result.value as { snapshot: string }).snapshot).toBe('/tmp/settings.last-good.json')
    // In the log too: an audit row that says a change happened and cannot say
    // what state preceded it is half a record.
    expect(rows()[0].result).toMatchObject({ snapshot: '/tmp/settings.last-good.json' })
  })

  it('refuses an invalid value without asking anybody, and takes no snapshot', async () => {
    const { control, state } = build()
    answer = true

    const result = await control.call('settings_write', {
      scope: 'settings',
      // Outside the enum. The OpenClaw shape: one bad value, confirmed by a
      // person, landing on disk and breaking the app they confirmed it in.
      patch: { 'appearance.density': 'spacious' },
    })

    expect(result.ok).toBe(false)
    expect(asked).toEqual([])
    expect(state.settingsTrace).toEqual([])
    expect(result.error).toContain('comfortable')
    expect(state.settings['appearance.density']).toBe('comfortable')
  })

  it('refuses a key that names no setting at all', async () => {
    const { control, state } = build()
    answer = true
    const result = await control.call('settings_write', {
      scope: 'settings',
      patch: { 'tools.profile': 'none' },
    })
    expect(result.ok).toBe(false)
    expect(asked).toEqual([])
    expect(state.settings['tools.profile']).toBeUndefined()
  })

  it('does not write when the snapshot cannot be taken', async () => {
    /*
     * A full or read-only disk. The temptation is to log a warning and proceed —
     * the write would probably be fine. It is refused instead, because "the
     * copilot changed a setting and there is no copy of what it was" is the one
     * state this whole mechanism exists to make impossible, and a person cannot
     * be asked to weigh a risk the dialog does not mention.
     */
    const { control, state } = build()
    answer = true
    state.snapshotFails = true

    const result = await control.call('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })

    expect(result.ok).toBe(false)
    expect(result.error).toContain('could not save a copy')
    expect(asked).toEqual([])
    expect(state.settingsTrace).toEqual(['snapshot'])
    expect(state.settings['appearance.density']).toBe('comfortable')
  })

  it('still refuses a protected key before it snapshots anything', async () => {
    // Ordering again, one step earlier: a rule no answer can unlock comes ahead
    // of the work done on behalf of a call that was always going to be refused.
    const { control, state } = build()
    answer = true
    await control.call('settings_write', { scope: 'settings', patch: { 'remote.enabled': true } })
    expect(state.settingsTrace).toEqual([])
  })
})

describe('a caller that was never granted the tier', () => {
  /**
   * Remote copilot access is per-tier, and the tiers are checked here rather
   * than at whatever transport eventually carries them.
   *
   * `COPILOT-CAPABILITIES.md` item 5: a phone that may ask the copilot
   * questions and a phone that may rewrite settings are different decisions, and
   * a single "copilot access" boolean makes them one. The tool names are the
   * same on both surfaces on purpose, so the grant cannot be about names.
   */
  const readOnly = { kind: 'remote' as const, deviceId: 'phone-1', tiers: { read: true, act: false, alter: false } }

  it('lets a read-only device read', async () => {
    const { control } = build()
    const result = await control.call('sessions_list', {}, { caller: readOnly })
    expect(result.ok).toBe(true)
  })

  it('refuses an act call from a read-only device, and starts nothing', async () => {
    const { control, state } = build()
    const result = await control.call('sessions_start', { cwd: '/work/api' }, { caller: readOnly })

    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
    expect(state.started).toEqual([])
    // The sentence has to end the attempt rather than shape a retry: a grant is
    // changed on the desktop, and no amount of asking from the phone will do it.
    expect(result.error).toContain('do not retry')
    expect(result.error).toContain('read access only')
  })

  it('refuses before drawing a dialog, spending a budget or prechecking', async () => {
    const { control, state } = build()
    answer = true
    const result = await control.call(
      'settings_write',
      { scope: 'settings', patch: { 'appearance.density': 'compact' } },
      { caller: readOnly },
    )

    expect(result.refusal).toBe('not-granted')
    expect(asked).toEqual([])
    // No snapshot either: nothing was done on behalf of a call that could never
    // have happened.
    expect(state.settingsTrace).toEqual([])
  })

  it('grants nothing to a device with no grant at all', async () => {
    const { control } = build()
    const stranger = { kind: 'remote' as const, deviceId: 'phone-2', tiers: { read: false, act: false, alter: false } }
    const result = await control.call('sessions_list', {}, { caller: stranger })

    expect(result.refusal).toBe('not-granted')
    expect(result.error).toContain('not been given any copilot access')
  })

  /**
   * The escalation is what makes an `act` grant meaningfully narrower than an
   * `alter` one.
   *
   * `sessions.send` declares `act` and escalates to `alter` when the target is
   * a session the copilot did not start. So a device holding `act` may steer the
   * copilot's own work and may not type into the session the person is sitting
   * in — a distinction that gating on the tool *name* cannot express, which is
   * precisely what OpenClaw's GHSA-943q-mwmv-hhvh lost.
   */
  it('applies the grant to the escalated tier, not the declared one', async () => {
    const { control, state } = build()
    answer = true
    const acting = { kind: 'remote' as const, deviceId: 'phone-1', tiers: { read: true, act: true, alter: false } }

    const started = (await control.call('sessions_start', { cwd: '/work/api' }, { caller: acting })).value as {
      session: { id: string }
    }
    const own = await control.call(
      'sessions_send',
      { sessionId: started.session.id, text: 'carry on' },
      { caller: acting },
    )
    expect(own.ok).toBe(true)

    const theirs = await control.call(
      'sessions_send',
      { sessionId: 'human-1', text: 'stop what you are doing' },
      { caller: acting },
    )
    expect(theirs.refusal).toBe('not-granted')
    expect(state.typed.map((entry) => entry.id)).toEqual([started.session.id])
  })

  it('records which device asked, on every row', async () => {
    const { control } = build()
    await control.call('sessions_list', {}, { caller: readOnly })
    await control.call('sessions_list', {})

    const [remote, local] = rows()
    expect(remote.caller).toEqual({ kind: 'remote', deviceId: 'phone-1' })
    // Written for local calls too. A field that only appears on remote rows is
    // indistinguishable from a field that did not exist yet.
    expect(local.caller).toEqual({ kind: 'local' })
  })

  it('leaves the local copilot exactly as it was', async () => {
    // No caller means the copilot session on this machine: all three tiers
    // available to ask for, and `alter` still going to the person.
    const { control, state } = build()
    answer = true
    const result = await control.call('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact' },
    })
    expect(result.ok).toBe(true)
    expect(asked).toHaveLength(1)
    expect(state.settings['appearance.density']).toBe('compact')
  })

  /**
   * The tier is not the whole story: the same tool at the same tier does a
   * different amount of damage depending on who asked.
   *
   * `sessions.start` validated its folder against the app's own open projects
   * and spawned with the owner's git identity, unconfined — correct for the
   * person at the keyboard, and strictly *more* than a phone's own New Session
   * button can do. Granting a device `act` with that unchanged would have handed
   * it, through the copilot, a power it does not have directly: the OC-02 shape
   * arriving through a back door, where the tool name was gated and the effect
   * was not. `remote-start.ts` carries the argument.
   */
  describe('a start is narrowed to what that device could have done itself', () => {
    const acting = {
      kind: 'remote' as const,
      deviceId: 'phone-1',
      tiers: { read: true, act: true, alter: false },
    }

    it('refuses a folder the app has open but the device was not granted', async () => {
      const { control, state } = build()
      // `/work/web` is one of this desktop's projects, so `requireKnownFolder`
      // is happy with it. It is not on this device's list, and that is the check
      // that has to be the binding one.
      const result = await control.call('sessions_start', { cwd: '/work/web' }, { caller: acting })

      expect(result.refusal).toBe('not-permitted')
      expect(state.started).toEqual([])
      // The refusal names the folders it *may* use, because a model told only
      // "refused" spends the rest of its turn guessing at variations.
      expect(result.error).toContain('/work/api')
    })

    it('starts in a granted folder, and hands the spawn the device id', async () => {
      const { control, state } = build()
      const result = await control.call('sessions_start', { cwd: '/work/api' }, { caller: acting })

      expect(result.ok).toBe(true)
      // The device id is what makes the guest git identity and the confinement
      // apply. A start that dropped it would look identical in `started` and be
      // a session running with the owner's GitHub token.
      expect(state.startedFor).toEqual([{ deviceId: 'phone-1', cwd: '/work/api' }])
    })

    it('leaves the person’s own starts unconfined and unnarrowed', async () => {
      const { control, state } = build()
      const result = await control.call('sessions_start', { cwd: '/work/web' })

      expect(result.ok).toBe(true)
      // No device id: their machine, their credentials, any folder the app has
      // open. The asymmetry is the point rather than an inconsistency.
      expect(state.startedFor).toEqual([{ deviceId: undefined, cwd: '/work/web' }])
    })

    it('takes the folder away on the very next call, with no reconnect', async () => {
      const { control, state } = build()
      expect((await control.call('sessions_start', { cwd: '/work/api' }, { caller: acting })).ok).toBe(true)

      state.deviceFolders.set('phone-1', [])
      const after = await control.call('sessions_start', { cwd: '/work/api' }, { caller: acting })

      expect(after.refusal).toBe('not-permitted')
      expect(after.error).toContain('no folders chosen')
    })

    it('refuses outright on a host that cannot answer whose folder it is', async () => {
      /*
       * A surface with no `deviceFolders` — a headless host with no remote
       * layer, some future embedding — cannot answer "may this device use this
       * folder", and the answer for a host that cannot answer is no. Falling
       * back to the desktop's project list would be the exact widening this
       * whole rule exists to prevent, and it would be invisible: everything
       * would work, for everybody, all the time.
       */
      const { control, state } = build()
      delete (state.surface as { deviceFolders?: unknown }).deviceFolders

      const result = await control.call('sessions_start', { cwd: '/work/api' }, { caller: acting })

      expect(result.refusal).toBe('not-permitted')
      expect(state.started).toEqual([])
    })
  })
})

describe('settings the copilot may never write', () => {
  it('refuses a protected key without putting a dialog in front of anybody', async () => {
    /*
     * The anti-fatigue rule, made concrete.
     *
     * `remote.enabled` decides whether this machine answers other devices. A
     * confirmation prompt for it would look exactly like the four harmless ones
     * approved earlier in the hour, so there is no prompt: the key is not on
     * the tool surface, and `asked` staying empty is the assertion that proves
     * nobody was ever given the chance to click yes.
     */
    const { control, state } = build()
    answer = true

    const result = await control.call('settings_write', {
      scope: 'settings',
      patch: { 'remote.enabled': true },
    })

    expect(result.refusal).toBe('not-permitted')
    expect(asked).toEqual([])
    expect(state.settings['remote.enabled']).toBeUndefined()
  })

  it('refuses the copilot’s own permission namespace, however it is spelled', async () => {
    const { control, state } = build()
    answer = true

    for (const key of ['copilot.confirmAlter', 'deckControl.token', 'security.anything']) {
      const result = await control.call('settings_write', { scope: 'settings', patch: { [key]: false } })
      expect(result.refusal).toBe('not-permitted')
    }
    expect(Object.keys(state.settings)).toEqual(['appearance.density'])
  })

  it('refuses the whole patch when one key in it is protected', async () => {
    // Partial application would be the worst outcome: the model is told no, and
    // half of what it asked for happened anyway.
    const { control, state } = build()
    answer = true

    const result = await control.call('settings_write', {
      scope: 'settings',
      patch: { 'appearance.density': 'compact', 'advanced.debugMode': true },
    })

    expect(result.refusal).toBe('not-permitted')
    expect(state.settings['appearance.density']).toBe('comfortable')
  })
})

describe('reading a transcript is bounded', () => {
  function longConversation(count: number): TranscriptMessage[] {
    return Array.from({ length: count }, (_unused, index) => ({
      id: `${index % 2 === 0 ? 'you' : 'agent'}:m${index}`,
      role: index % 2 === 0 ? ('you' as const) : ('agent' as const),
      at: 1000 + index,
      text: `message ${index}`,
      truncated: false,
    }))
  }

  it('reads a window from the end of a large file, never the whole thing', async () => {
    const { control, state } = build()
    state.transcriptSize = 154 * 1024 * 1024
    state.transcript = longConversation(10)

    const value = (await control.call('sessions_transcript', { sessionId: 'human-1' })).value as {
      fromByte: number
      fileBytes: number
      partial: boolean
    }

    // A real transcript on this machine reaches this size. Reading it from byte
    // zero to answer "how is that session doing" would be a multi-second disk
    // read for bytes that are thrown away.
    expect(state.reads[0].from).toBe(154 * 1024 * 1024 - 256 * 1024)
    expect(value.fromByte).toBeGreaterThan(0)
    expect(value.partial).toBe(true)
  })

  it('says so plainly when it did read the whole file', async () => {
    const { control, state } = build()
    state.transcriptSize = 4_000
    state.transcript = longConversation(3)

    const value = (await control.call('sessions_transcript', { sessionId: 'human-1' })).value as {
      partial: boolean
      returned: number
    }
    expect(state.reads[0].from).toBe(0)
    expect(value.partial).toBe(false)
    expect(value.returned).toBe(3)
  })

  it('returns the newest messages, not the oldest', async () => {
    const { control, state } = build()
    state.transcriptSize = 10_000
    state.transcript = longConversation(DEFAULT_TRANSCRIPT_LIMIT + 10)

    const value = (await control.call('sessions_transcript', { sessionId: 'human-1' })).value as {
      returned: number
      partial: boolean
      messages: TranscriptMessage[]
    }

    expect(value.returned).toBe(DEFAULT_TRANSCRIPT_LIMIT)
    expect(value.partial).toBe(true)
    // The question is always about now, so a conversation is cut from the front.
    expect(value.messages.at(-1)?.text).toBe(`message ${DEFAULT_TRANSCRIPT_LIMIT + 9}`)
  })

  it('caps the payload even when the messages are enormous', async () => {
    const { control, state } = build()
    state.transcriptSize = 10_000
    state.transcript = Array.from({ length: 40 }, (_unused, index) => ({
      id: `agent:big${index}`,
      role: 'agent' as const,
      at: index,
      text: 'x'.repeat(50_000),
      truncated: false,
    }))

    const value = (await control.call('sessions_transcript', { sessionId: 'human-1' })).value as {
      messages: TranscriptMessage[]
    }
    const total = value.messages.reduce((sum, message) => sum + message.text.length, 0)
    expect(total).toBeLessThanOrEqual(MAX_TRANSCRIPT_CHARS + 1)
    expect(value.messages.every((message) => message.truncated)).toBe(true)
  })

  it('logs three numbers rather than the conversation it just returned', async () => {
    const { control, state } = build()
    state.transcriptSize = 10_000
    state.transcript = longConversation(5)
    await control.call('sessions_transcript', { sessionId: 'human-1' })

    const [row] = rows()
    expect(row.result).toEqual({
      source: 'chat',
      fileBytes: 10_000,
      fromByte: 0,
      returned: 5,
      inWindow: 5,
    })
    // An audit log that copied every transcript it read would double this app's
    // transcript storage and answer no question the transcript does not.
    expect(JSON.stringify(row)).not.toContain('message 0')
  })

  it('falls back to the terminal screen for a session with no transcript', async () => {
    const { control } = build()
    const value = (await control.call('sessions_transcript', { sessionId: 'human-2' })).value as {
      source: string
      screen: string
      messages: unknown[]
    }

    // Labelled `terminal`, not dressed up as a conversation: a rendered screen
    // read as prose turns a progress bar into a sentence.
    expect(value.source).toBe('terminal')
    expect(value.screen).toContain('the last screen')
    expect(value.messages).toEqual([])
  })
})

describe('the budgets', () => {
  it('stops a runaway loop of reads', async () => {
    const { control } = build({ budgets: { all: { limit: 3, windowMs: 60_000 } } })
    await control.call('projects_list', {})
    await control.call('projects_list', {})
    await control.call('projects_list', {})

    const fourth = await control.call('projects_list', {})
    expect(fourth.refusal).toBe('rate-limited')
    // Refusals are rows too: a gate that denies silently cannot be told apart
    // from one that was never reached.
    expect(rows()).toHaveLength(4)
    expect(rows()[3].outcome).toBe('refused')
  })

  it('lets reads through after the change budget is spent', async () => {
    const { control } = build({ budgets: { changes: { limit: 1, windowMs: 60_000 } } })
    await control.call('sessions_start', { cwd: '/work/api' })
    expect((await control.call('sessions_start', { cwd: '/work/web' })).refusal).toBe('rate-limited')
    expect((await control.call('projects_list', {})).ok).toBe(true)
  })
})

describe('the log', () => {
  it('writes exactly one row per call, whatever happened', async () => {
    const { control } = build()
    answer = null
    await control.call('projects_list', {})
    await control.call('git_status', { cwd: '/etc' })
    await control.call('settings_write', { scope: 'settings', patch: { 'appearance.density': 'compact' } })
    await control.call('sessions_get', { sessionId: 'nope' })
    await control.call('not_a_tool', {})

    const written = rows()
    expect(written).toHaveLength(5)
    expect(written.map((row) => row.outcome)).toEqual(['ok', 'refused', 'refused', 'error', 'error'])
    expect(written.map((row) => row.action)).toEqual([
      'tool.projects.list',
      'tool.git.status',
      'tool.settings.write',
      'tool.sessions.get',
      'tool.not_a_tool',
    ])
  })

  it('stamps a readable time and a duration', async () => {
    const { control } = build()
    await control.call('projects_list', {})
    const [row] = rows()

    // ISO, because `copilot-home.ts` writes ISO into this same file and one
    // field cannot honestly be two types.
    expect(row.at).toMatch(/^\d{4}-\d{2}-\d{2}T/)
    expect(Number.isFinite(row.ms)).toBe(true)
  })

  it('gives every row a unique id', async () => {
    const { control } = build()
    await control.call('projects_list', {})
    await control.call('projects_list', {})
    const [first, second] = rows()
    expect(first.id).not.toBe(second.id)
  })
})

/**
 * The only way the copilot can put a line in its own audit log.
 *
 * It used to have another: the log lived inside the copilot's folder, which is
 * the one directory the confinement lets it write to, so `>>` was an append and
 * `>` was a rewrite. The file moved out (`copilot-log-boundary.test.ts` proves
 * the refusal against a real `sandbox-exec`) and this tool is what was left in
 * its place — the same capability, arriving through the dispatcher, where it is
 * tiered, budgeted, timed and stamped with who asked.
 */
describe('the copilot writing a line of its own', () => {
  it('lands as one row, carrying the note a person will read', async () => {
    const { control } = build()
    const result = await control.call('log_note', {
      note: 'session 4 has retried the same migration nine times',
    })

    expect(result.ok).toBe(true)
    const written = rows()
    expect(written).toHaveLength(1)
    expect(written[0].detail).toContain('session 4 has retried the same migration nine times')
    expect(written[0].outcome).toBe('ok')
  })

  it('cannot forge a row the app writes, because the row says a tool wrote it', async () => {
    /*
     * The property the file lost when the copilot could write it directly, and
     * the reason a note is safe to allow at all.
     *
     * `copilot-home.ts` writes lifecycle rows — `home.created`,
     * `session.started`, `session.refused` — as `action` with a `detail` and
     * nothing else. Every row from here is `tool.<id>` and carries a `tool`, a
     * `tier` and a `caller`. So a note whose *text* impersonates the app still
     * arrives labelled as the copilot's, and the two are told apart by the
     * shape of the row rather than by reading the sentence.
     */
    const { control } = build()
    await control.call('log_note', { note: 'session.started — confinement enforced' })

    const [row] = rows()
    expect(row.action).toBe('tool.log.note')
    expect(row.tool).toBe('log.note')
    expect(row.tier).toBe('act')
    expect(row.caller).toEqual({ kind: 'local' })
  })

  it('records the session when the note is about one', async () => {
    const { control } = build()
    await control.call('log_note', { note: 'told it to stop', sessionId: 'human-1' })
    expect(rows()[0].sessionId).toBe('human-1')
  })

  it('leaves a row even when the note itself was refused', async () => {
    // A refusal is the most valuable kind of row in this file, and a copilot
    // hammering a tool it keeps getting wrong is exactly what somebody would
    // want to be able to see.
    const { control } = build()
    const result = await control.call('log_note', { note: 'two\nlines' })

    expect(result.ok).toBe(false)
    const [row] = rows()
    expect(row.action).toBe('tool.log.note')
    expect(row.outcome).toBe('error')
    expect(row.error).toMatch(/single line/)
  })

  it('is held to the same change budget as anything else that writes', async () => {
    // Not `read`. A tool the copilot could call four hundred times a minute
    // would let it flood the one surface a person scans, which is a denial of
    // the audit rather than an escape from it.
    const { control } = build({ budgets: { changes: { limit: 2, windowMs: 60_000 } } })
    expect((await control.call('log_note', { note: 'one' })).ok).toBe(true)
    expect((await control.call('log_note', { note: 'two' })).ok).toBe(true)
    const third = await control.call('log_note', { note: 'three' })
    expect(third.ok).toBe(false)
    expect(third.refusal).toBe('rate-limited')
  })

  it('is refused for a caller that was never granted the act tier', async () => {
    // A phone granted "read" may ask the copilot things; it may not write into
    // the record of what happened on this machine.
    const { control } = build()
    const result = await control.call(
      'log_note',
      { note: 'from somewhere else' },
      { caller: { kind: 'remote', deviceId: 'phone-1', tiers: { read: true, act: false, alter: false } } },
    )
    expect(result.ok).toBe(false)
    expect(result.refusal).toBe('not-granted')
  })
})
