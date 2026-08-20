import { describe, expect, it } from 'vitest'
import {
  MAX_NOTE_CHARS,
  MAX_QUOTE_CHARS,
  MAX_TOUR_STOPS,
  TourRefused,
  openRecord,
  parseTourPlan,
  validateTour,
  type TourPlan,
} from './tour'
import type { DeckSurface, SessionView, TranscriptMessage } from './surface'

/**
 * What a tour is allowed to show, and what it is not.
 *
 * Two rules carry the whole feature and both are checked here rather than
 * trusted:
 *
 *  - **A plan over budget is refused, not truncated.** Truncation lets a bad
 *    plan half-succeed, and a model that learns overreaching is free will
 *    overreach every time.
 *  - **A stop the app's own data will not stand behind is dropped, and the drop
 *    is reported.** That is what makes a fabricated quote undisplayable rather
 *    than merely discouraged — the copilot's raw material is other agents'
 *    output, which `COPILOT-CAPABILITIES.md` §3.2 item 8 classes as evidence
 *    from an untrusted source.
 */

const ESC = '\u001b'

function sessionView(over: Partial<SessionView> = {}): SessionView {
  return {
    id: 's1',
    cwd: '/work/api',
    title: 'api',
    provider: 'shell',
    status: 'idle',
    windows: [],
    statusSince: 1_000,
    attention: 'quiet',
    attentionReason: 'no-output',
    attentionForMs: 0,
    statusSource: 'screen',
    createdAt: 1_000,
    exitCode: null,
    resumed: false,
    profileName: null,
    startedByCopilot: false,
    ...over,
  }
}

interface Rig {
  screen?: string
  messages?: TranscriptMessage[]
  changedPaths?: string[]
  transcript?: boolean
}

function surfaceFor(rig: Rig): DeckSurface {
  const messages = rig.messages ?? []
  const paths = rig.changedPaths ?? []
  const has = rig.transcript !== false && messages.length > 0
  return {
    listSessions: () => [
      { id: 's1', cwd: '/work/api', title: 'api', provider: 'shell', exitCode: null, createdAt: 1_000 },
    ],
    sessionStatus: () => null,
    startSession: async () => {
      throw new Error('not used')
    },
    writeToSession: () => undefined,
    killSession: () => undefined,
    sessionScreen: async () => rig.screen ?? '',
    sessionScrollback: () => rig.screen ?? '',
    listProjects: () => [{ path: '/work/api', lastOpenedAt: 1 }],
    appStateRoot: () => '/state',
    copilotRoot: () => '/state/copilot',
    gitStatus: async () => ({}),
    alerts: async () => [],
    readSettings: () => ({ settings: {}, preferences: {} }),
    writeSettings: () => ({}),
    writePreferences: () => ({}),
    snapshotSettings: () => ({ path: '/state/last-good.json', at: 1 }),
    transcriptsIn: async () =>
      has ? [{ path: '/t/one.jsonl', sessionId: 'x', createdAt: 900, modifiedAt: 1_100, bytes: 400 }] : [],
    transcriptBytes: async () => 400,
    readTranscriptFrom: async () => messages,
    readToolTrail: async () => ({ events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({
      repo: true,
      root: '/work/api',
      branch: 'main',
      ahead: 0,
      behind: 0,
      files: paths.map((path) => ({
        path,
        group: 'unstaged' as const,
        kind: 'modified',
        insertions: 1,
        deletions: 1,
        binary: false,
      })),
      reason: null,
    }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
  }
}

function plan(stops: unknown[]): Record<string, unknown> {
  return { question: 'what happened?', headline: 'this happened', stops }
}

const SCREEN_STOP = {
  kind: 'screen',
  sessionId: 's1',
  quote: 'the build failed',
  note: 'it failed',
  why: 'files-changed',
}

async function check(raw: Record<string, unknown>, rig: Rig, session = sessionView()) {
  const parsed = parseTourPlan(raw)
  return await validateTour(parsed, { surface: surfaceFor(rig), sessions: [session], now: 2_000 })
}

/* ------------------------------------------------------------- the budget -- */

describe('a plan over budget is refused rather than trimmed', () => {
  const one = (index: number) => ({ ...SCREEN_STOP, note: `note ${index}` })

  it('refuses a thirteenth stop and says which limit and by how much', () => {
    const stops = Array.from({ length: MAX_TOUR_STOPS + 1 }, (_unused, index) => one(index))
    expect(() => parseTourPlan(plan(stops))).toThrow(TourRefused)
    try {
      parseTourPlan(plan(stops))
    } catch (error) {
      const message = (error as Error).message
      expect(message).toContain(String(MAX_TOUR_STOPS))
      expect(message).toContain(String(MAX_TOUR_STOPS + 1))
      // The refusal has to say *why* it is a refusal rather than a trim, or the
      // next plan is the same plan with the model hoping for a different answer.
      expect(message).toContain('refused rather than trimmed')
    }
  })

  it('takes exactly twelve', () => {
    const stops = Array.from({ length: MAX_TOUR_STOPS }, (_unused, index) => one(index))
    expect(parseTourPlan(plan(stops)).stops).toHaveLength(MAX_TOUR_STOPS)
  })

  it('refuses an over-long quote', () => {
    const stops = [{ ...SCREEN_STOP, quote: 'x'.repeat(MAX_QUOTE_CHARS + 1) }]
    expect(() => parseTourPlan(plan(stops))).toThrow(/600/)
  })

  it('refuses an over-long note', () => {
    const stops = [{ ...SCREEN_STOP, note: 'x'.repeat(MAX_NOTE_CHARS + 1) }]
    expect(() => parseTourPlan(plan(stops))).toThrow(/160/)
  })

  it('refuses a plan with no stops at all', () => {
    expect(() => parseTourPlan(plan([]))).toThrow(TourRefused)
  })

  it('refuses a reason this app does not check, and lists the ones it does', () => {
    expect(() => parseTourPlan(plan([{ ...SCREEN_STOP, why: 'looks-bad' }]))).toThrow(
      /blocked-on-you/,
    )
  })

  it('refuses an anchor a tour cannot bring on screen', () => {
    // `session-row` and `alert` are real anchors and not tourable: the panel
    // covers the rail, and nothing a tour may call can open the alerts sheet.
    const stop = { kind: 'anchor', at: 'session-row', sessionId: 's1', note: 'n', why: 'files-changed' }
    expect(() => parseTourPlan(plan([stop]))).toThrow(/git-file/)
  })
})

/* -------------------------------------------------------------- the drops -- */

describe('a stop the app cannot stand behind is dropped, and the drop is reported', () => {
  it('drops a quote that was never on that terminal', async () => {
    const out = await check(plan([SCREEN_STOP]), { screen: 'everything is fine', changedPaths: ['a.ts'] })
    expect(out.plan.stops).toHaveLength(0)
    expect(out.dropped[0].why).toBe('quote-not-found')
  })

  it('keeps a quote that is really there', async () => {
    const out = await check(plan([SCREEN_STOP]), {
      screen: 'running\nthe build failed\n',
      changedPaths: ['a.ts'],
    })
    expect(out.plan.stops).toHaveLength(1)
    expect(out.dropped).toHaveLength(0)
  })

  it('finds a quote that the terminal coloured', async () => {
    // The measured defect: the retained scrollback is what the process wrote,
    // and a needle taken off the rendered screen has none of the escapes in it.
    const out = await check(plan([SCREEN_STOP]), {
      screen: `${ESC}[31mthe build failed${ESC}[m\n`,
      changedPaths: ['a.ts'],
    })
    expect(out.plan.stops).toHaveLength(1)
  })

  it('drops a reason the app’s own data contradicts, and says what it says instead', async () => {
    const stop = { ...SCREEN_STOP, why: 'blocked-on-you' }
    const out = await check(plan([stop]), { screen: 'the build failed', changedPaths: ['a.ts'] })
    expect(out.dropped[0].why).toBe('reason-unsupported')
    expect(out.dropped[0].detail).toContain('quiet')
  })

  it('keeps a reason the app’s own data supports', async () => {
    const out = await check(plan([SCREEN_STOP]), { screen: 'the build failed', changedPaths: ['a.ts'] })
    expect(out.plan.stops).toHaveLength(1)
  })

  it('drops files-changed when git reports nothing changed', async () => {
    const out = await check(plan([SCREEN_STOP]), { screen: 'the build failed', changedPaths: [] })
    expect(out.dropped[0].why).toBe('reason-unsupported')
  })

  it('drops a stop about a session that has gone', async () => {
    const stop = { ...SCREEN_STOP, sessionId: 'ghost' }
    const parsed = parseTourPlan(plan([stop]))
    const out = await validateTour(parsed, {
      surface: surfaceFor({ screen: 'the build failed' }),
      sessions: [sessionView()],
      now: 2_000,
    })
    expect(out.dropped[0].why).toBe('session-gone')
  })

  it('drops a git-file anchor naming a file git does not report as changed', async () => {
    const stop = {
      kind: 'anchor',
      at: 'git-file',
      path: 'never-touched.ts',
      sessionId: 's1',
      note: 'n',
      why: 'files-changed',
    }
    const out = await check(plan([stop]), { screen: '', changedPaths: ['a.ts'] })
    expect(out.dropped[0].why).toBe('quote-not-found')
  })

  /*
   * A `message` stop needs a session with a *transcript*, which means a Claude
   * session: `transcript-match.ts` refuses to hand a conversation to a shell,
   * because a shell writes none and counting it as a candidate owner was how
   * one folder's four sessions were each reported with a fourth's work.
   */
  const claude = () => sessionView({ provider: 'claude' })

  it('drops a cited message that does not exist', async () => {
    const stop = {
      kind: 'message',
      sessionId: 's1',
      messageId: 'agent:nope',
      quote: 'all done',
      note: 'n',
      why: 'files-changed',
    }
    const out = await check(plan([stop]), {
      messages: [{ id: 'agent:m1', role: 'agent', at: 1, text: 'all done', truncated: false }],
      changedPaths: ['a.ts'],
    }, claude())
    expect(out.dropped[0].why).toBe('quote-not-found')
    expect(out.dropped[0].detail).toContain('agent:nope')
  })

  it('drops a message stop whose quote is not in the message it cites', async () => {
    const stop = {
      kind: 'message',
      sessionId: 's1',
      messageId: 'agent:m1',
      quote: 'I deleted the database',
      note: 'n',
      why: 'files-changed',
    }
    const out = await check(plan([stop]), {
      messages: [{ id: 'agent:m1', role: 'agent', at: 1, text: 'all done', truncated: false }],
      changedPaths: ['a.ts'],
    }, claude())
    expect(out.dropped[0].detail).toContain('does not contain')
  })

  it('keeps a message stop whose quote is really in it', async () => {
    const stop = {
      kind: 'message',
      sessionId: 's1',
      messageId: 'agent:m1',
      quote: 'the migration ran twice',
      note: 'n',
      why: 'files-changed',
    }
    const out = await check(plan([stop]), {
      messages: [
        { id: 'agent:m1', role: 'agent', at: 1, text: 'so the migration ran twice, sorry', truncated: false },
      ],
      changedPaths: ['a.ts'],
    }, claude())
    expect(out.plan.stops).toHaveLength(1)
  })
})

/* ------------------------------------------------------------- `decision` -- */

describe('the one reason with no detector is bounded instead of checked', () => {
  const decision = (note: string) => ({ ...SCREEN_STOP, why: 'decision', note })

  it('allows one per session', async () => {
    const out = await check(plan([decision('a')]), { screen: 'the build failed' })
    expect(out.plan.stops).toHaveLength(1)
  })

  it('drops the second, because that is the whole of the bound', async () => {
    const out = await check(plan([decision('a'), decision('b')]), { screen: 'the build failed' })
    expect(out.plan.stops).toHaveLength(1)
    expect(out.dropped[0].why).toBe('over-budget')
  })

  it('still checks its quote, so it cannot be used to say anything at all', async () => {
    const stop = { ...decision('a'), quote: 'a thing nobody printed' }
    const out = await check(plan([stop]), { screen: 'the build failed' })
    expect(out.plan.stops).toHaveLength(0)
    expect(out.dropped[0].why).toBe('quote-not-found')
  })
})

/* --------------------------------------------------------------- the record -- */

describe('the record opened before anything is shown', () => {
  it('carries the checked quote, the drops, and enough to point at the stop again', async () => {
    const out = await check(plan([SCREEN_STOP, { ...SCREEN_STOP, quote: 'never printed' }]), {
      screen: 'the build failed',
      changedPaths: ['a.ts'],
    })
    const record = openRecord(out, 5_000)

    expect(record.startedAt).toBe(5_000)
    expect(record.endedAt).toBeNull()
    // Nothing is shown yet, and the record says so rather than assuming.
    expect(record.stops.every((stop) => stop.shownAt === null)).toBe(true)
    expect(record.stops[0].quote).toBe('the build failed')
    expect(record.stops[0].kind).toBe('screen')
    expect(record.stops[0].cwd).toBe('/work/api')
    expect(record.stops[0].sessionTitle).toBe('api')
    expect(record.dropped).toHaveLength(1)
  })

  it('gives a fresh id per plan', () => {
    const a = parseTourPlan(plan([SCREEN_STOP]))
    const b = parseTourPlan(plan([SCREEN_STOP]))
    expect(a.id).not.toBe(b.id)
    expect(a.id).toMatch(/^tour_\d+_[0-9a-f]{8}$/)
  })

  it('keeps the question and the headline verbatim', () => {
    const parsed: TourPlan = parseTourPlan({
      question: 'what happened while I was away?',
      headline: 'One thing needs you.',
      stops: [SCREEN_STOP],
    })
    expect(parsed.question).toBe('what happened while I was away?')
    expect(parsed.headline).toBe('One thing needs you.')
  })
})
