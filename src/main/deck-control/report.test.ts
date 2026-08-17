import { describe, expect, it } from 'vitest'
import { HEAVY_MIN_TOKENS } from './importance'
import {
  MAX_LAST_MESSAGE_CHARS,
  reportOnFleet,
  reportOnSession,
  TOTALS_MAX_BYTES,
  TRAIL_WINDOW_BYTES,
} from './report'
import type {
  DeckSurface,
  RepoChanges,
  SessionView,
  ToolEvent,
  ToolTrail,
  TranscriptMessage,
  TranscriptTotals,
} from './surface'

/**
 * The answer to "how did that go", and the promise that every claim in it
 * points at something.
 *
 * The assertions below are mostly about *pointers and refusals* rather than
 * about prose: the transcript path and the byte range that was parsed, the
 * reason a total was not read, the reason a session has no progress verdict.
 * A recap is only worth writing if it shortens verification, and it only
 * shortens verification if the reader can get from a sentence to the file it
 * came from without asking a second question.
 */

type ReportSurface = Pick<
  DeckSurface,
  | 'transcriptsIn'
  | 'listSessions'
  | 'transcriptBytes'
  | 'readTranscriptFrom'
  | 'readToolTrail'
  | 'transcriptTotals'
  | 'gitChanges'
  | 'fileModifiedAt'
>

function view(over: Partial<SessionView> = {}): SessionView {
  return {
    id: 'one',
    cwd: '/work/api',
    title: 'api',
    provider: 'claude',
    status: 'working',
    statusSince: 10_000,
    createdAt: 1_000,
    exitCode: null,
    resumed: false,
    profileName: null,
    startedByCopilot: false,
    attention: 'running',
    attentionReason: 'output-streaming',
    attentionForMs: 0,
    statusSource: 'screen',
    ...over,
  }
}

/** The floor `importance.ts` and `alerts.ts` both put under "expensive". */
const HEAVY = HEAVY_MIN_TOKENS

/** A usage record totalling `total` tokens, spread the way a real one is. */
function bigUsage(total: number): TranscriptTotals['usage'] {
  const share = Math.round(total / 4)
  return { input: share, output: share, cacheWrite5m: share, cacheWrite1h: 0, cacheRead: total - share * 3 }
}

function totals(over: Partial<TranscriptTotals> = {}): TranscriptTotals {
  return {
    requests: 12,
    usage: { input: 100, output: 200, cacheWrite5m: 300, cacheWrite1h: 0, cacheRead: 400 },
    models: ['claude-opus-5'],
    compactions: 1,
    context: { tokens: 90_000, window: 200_000, percent: 45, remaining: 110_000, level: 'ok' },
    startedAt: 1_000,
    lastActivityAt: 20_000,
    ...over,
  }
}

interface RigOptions {
  transcript?: string | null
  bytes?: number
  events?: ToolEvent[]
  messages?: TranscriptMessage[]
  totals?: TranscriptTotals | null
  changes?: Partial<RepoChanges>
}

interface Rig {
  surface: ReportSurface
  trailAsked: Array<{ path: string; windowBytes: number }>
  totalsAsked: string[]
}

function rig(options: RigOptions = {}): Rig {
  const trailAsked: Array<{ path: string; windowBytes: number }> = []
  const totalsAsked: string[] = []
  const path = options.transcript === undefined ? '/store/a.jsonl' : options.transcript
  const bytes = options.bytes ?? 4096
  return {
    trailAsked,
    totalsAsked,
    surface: {
      /*
       * One conversation in the folder, born when the session did. That is the
       * unambiguous case — `transcript-match.test.ts` owns the ambiguous ones —
       * so these fixtures stay about the report rather than about the matching.
       */
      transcriptsIn: async () =>
        path === null ? [] : [{ path, sessionId: 'cli-1', createdAt: 1_000, modifiedAt: 2_000, bytes }],
      listSessions: () => [
        { id: 'one', cwd: '/work/api', title: 'api', provider: 'claude', exitCode: null, createdAt: 1_000 },
      ],
      transcriptBytes: async () => bytes,
      readTranscriptFrom: async () => options.messages ?? [],
      readToolTrail: async (asked, windowBytes): Promise<ToolTrail> => {
        trailAsked.push({ path: asked, windowBytes })
        return {
          events: options.events ?? [],
          compactions: [],
          fileBytes: bytes,
          fromByte: Math.max(0, bytes - windowBytes),
          partial: bytes > windowBytes,
        }
      },
      transcriptTotals: async (asked) => {
        totalsAsked.push(asked)
        return options.totals === undefined ? totals() : options.totals
      },
      gitChanges: async (): Promise<RepoChanges> => ({
        repo: true,
        root: '/work/api',
        branch: 'main',
        ahead: 0,
        behind: 0,
        files: [
          { path: 'src/a.ts', group: 'unstaged', kind: 'modified', insertions: 4, deletions: 2, binary: false },
        ],
        reason: null,
        ...options.changes,
      }),
      fileModifiedAt: async () => 5_000,
    },
  }
}

describe('reportOnSession', () => {
  it('carries the pointer for every claim it makes', async () => {
    const built = rig({ bytes: 9_000_000 })
    const report = await reportOnSession(built.surface, view())

    expect(report.transcript).toEqual({
      path: '/store/a.jsonl',
      bytes: 9_000_000,
      parsedFrom: 9_000_000 - TRAIL_WINDOW_BYTES,
      partial: true,
      // How this file was decided to be this session's. Every number below it
      // is only about this session if this says so.
      basis: 'only-one',
      ambiguous: false,
    })
    expect(report.changes?.paths).toEqual(['src/a.ts'])
    expect(report.spend?.requests).toBe(12)
    // Prompt and output together, cache included — the same figure the
    // inspector ranks on, so two panes cannot disagree about one session.
    expect(report.spend?.totalTokens).toBe(1000)
  })

  it('reads behaviour from a window and spend from the whole file', async () => {
    const built = rig()
    await reportOnSession(built.surface, view())
    expect(built.trailAsked).toEqual([{ path: '/store/a.jsonl', windowBytes: TRAIL_WINDOW_BYTES }])
    // The asymmetry is deliberate: "how is it behaving" is about the last few
    // minutes, "what has it spent" is about all of it.
    expect(built.totalsAsked).toEqual(['/store/a.jsonl'])
  })

  it('refuses to total a transcript too large to read inside a fleet report', async () => {
    const built = rig({ bytes: TOTALS_MAX_BYTES + 1 })
    const report = await reportOnSession(built.surface, view())
    expect(built.totalsAsked).toEqual([])
    expect(report.spend?.skipped).toMatch(/too large to total/)
  })

  it('reports a session with no transcript as unknowable, not as healthy', async () => {
    const built = rig({ transcript: null })
    const report = await reportOnSession(built.surface, view({ provider: 'shell' }))
    expect(report.transcript).toBeNull()
    expect(report.spend).toBeNull()
    expect(report.progress.verdict).toBe('unknown')
  })

  it('promotes the last thing the agent said, and nothing the tools said', async () => {
    const built = rig({
      messages: [
        { role: 'you', at: 1, text: 'do the thing', truncated: false },
        { role: 'agent', at: 2, text: 'starting', truncated: false },
        { role: 'agent', at: 3, text: 'done, tests pass', truncated: false },
      ],
    })
    const report = await reportOnSession(built.surface, view())
    expect(report.lastMessage?.text).toBe('done, tests pass')
  })

  it('cuts a very long final message and says it cut it', async () => {
    const built = rig({
      messages: [{ role: 'agent', at: 2, text: 'z'.repeat(MAX_LAST_MESSAGE_CHARS * 2), truncated: false }],
    })
    const report = await reportOnSession(built.surface, view())
    expect(report.lastMessage?.truncated).toBe(true)
    expect(report.lastMessage?.text.length).toBe(MAX_LAST_MESSAGE_CHARS + 1)
  })

  /**
   * The ordering claim, which is the same one `attention.ts` makes: a person is
   * blocking this session, so that is the first thing said about it whatever
   * else is true.
   */
  it('leads with the person being blocked, ahead of everything else', async () => {
    const built = rig()
    const report = await reportOnSession(
      built.surface,
      view({ attention: 'blocked', attentionReason: 'question-unanswered', attentionForMs: 25 * 60_000 }),
    )
    expect(report.verdict).toMatch(/^Blocked on you for 25 min/)
  })

  it('leads with a failed exit for a session that is over', async () => {
    const built = rig()
    const report = await reportOnSession(
      built.surface,
      view({ attention: 'done', attentionReason: 'process-failed', exitCode: 1, status: 'exited' }),
    )
    expect(report.verdict).toMatch(/^Exited 1/)
  })

  it('says what a finished session left behind', async () => {
    const built = rig()
    const report = await reportOnSession(
      built.surface,
      view({ attention: 'done', attentionReason: 'turn-finished', status: 'completed' }),
    )
    expect(report.verdict).toMatch(/Finished — 1 file changed/)
  })
})

describe('reportOnFleet', () => {
  it('summarises what needs a person first', async () => {
    const built = rig()
    const fleet = await reportOnFleet(
      built.surface,
      [
        view({ id: 'a', attention: 'blocked' }),
        view({ id: 'b', attention: 'done', exitCode: 2, status: 'exited' }),
        view({ id: 'c' }),
      ],
      { now: 100_000 },
    )
    expect(fleet.totals).toMatchObject({ sessions: 3, blocked: 1, failed: 1, running: 1 })
    expect(fleet.headline).toBe('3 sessions: 1 waiting on you, 1 failed, 1 still working.')
  })

  it('bounds how many sessions one report reads, and says how many it skipped', async () => {
    const built = rig()
    const many = Array.from({ length: 12 }, (_unused, index) => view({ id: `s${index}` }))
    const fleet = await reportOnFleet(built.surface, many, { now: 100_000, limit: 4 })
    expect(fleet.reports).toHaveLength(4)
    expect(fleet.omitted).toBe(8)
  })

  it('filters to what has actually been active in the window', async () => {
    const built = rig()
    const fleet = await reportOnFleet(
      built.surface,
      [
        view({ id: 'recent', statusSince: 95_000, createdAt: 95_000 }),
        view({ id: 'ancient', statusSince: 1_000, createdAt: 1_000 }),
      ],
      { now: 100_000, since: 90_000 },
    )
    expect(fleet.reports.map((report) => report.sessionId)).toEqual(['recent'])
  })

  it('says plainly when nothing ran, rather than returning an empty object', async () => {
    const built = rig()
    const fleet = await reportOnFleet(built.surface, [], { now: 100_000 })
    expect(fleet.headline).toBe('Nothing has run in that window.')
  })

  it('decides "expensive" against the fleet, which one session on its own cannot be', async () => {
    /*
     * The second pass. `expensive` is a comparison, so the first session read
     * has no fleet behind it yet — computed inline it would be false for
     * everybody, silently, and the one reason that needs the whole report would
     * be the one reason the report never produced.
     */
    // Six sessions, each in a folder of its own so each owns one conversation
    // unambiguously — the matching is `transcript-match.test.ts`'s subject, not
    // this one's. One of them is enormous; five is `HEAVY_MIN_SAMPLE`, which is
    // what makes a median mean anything at all.
    const sessions = Array.from({ length: 6 }, (_unused, index) =>
      view({ id: `s${index}`, cwd: `/work/p${index}` }),
    )
    const heavy = rig({ totals: totals({ usage: bigUsage(HEAVY * 8) }) })
    const light = rig({ totals: totals({ usage: bigUsage(HEAVY / 4) }) })
    let call = 0
    const mixed: ReportSurface = {
      ...heavy.surface,
      listSessions: () =>
        sessions.map((session) => ({
          id: session.id,
          cwd: session.cwd,
          title: session.title,
          provider: session.provider,
          exitCode: null,
          createdAt: session.createdAt,
        })),
      transcriptTotals: async (path) => (call++ === 0 ? heavy.surface : light.surface).transcriptTotals(path),
    }

    const fleet = await reportOnFleet(mixed, sessions, { now: 100_000 })
    expect(fleet.reports[0].spend?.totalTokens).toBe(HEAVY * 8)
    expect(fleet.reports[0].reasons.map((finding) => finding.why)).toContain('expensive')
    expect(fleet.reports[1].reasons.map((finding) => finding.why)).not.toContain('expensive')
  })
})

/**
 * The prose and the machine reasons are one judgement, and this is what keeps
 * them one.
 *
 * `verdictFor` writes the sentence a person reads at 09:00; `reasonsFor` in
 * `importance.ts` produces the set driving mode walks them through. Nothing
 * stops those two from drifting apart except a test that reads one against the
 * other — and drift here is not cosmetic: it is the morning summary naming a
 * different session as the important one from the tour that follows it.
 */
describe('the verdict and the reasons say the same thing', () => {
  const cases: Array<{ what: string; over: Partial<SessionView>; leads: string; opening: string }> = [
    {
      what: 'blocked on a person',
      over: { attention: 'blocked', attentionReason: 'question-unanswered', attentionForMs: 20 * 60_000 },
      leads: 'blocked-on-you',
      opening: 'Blocked on you',
    },
    {
      what: 'died with a non-zero exit',
      over: { attention: 'done', attentionReason: 'process-failed', status: 'exited', exitCode: 2 },
      leads: 'failed',
      opening: 'Exited 2',
    },
    {
      what: 'finished cleanly',
      over: { attention: 'done', attentionReason: 'process-exited', status: 'exited', exitCode: 0 },
      leads: 'finished',
      opening: 'Finished',
    },
  ]

  for (const entry of cases) {
    it(`agrees about a session that ${entry.what}`, async () => {
      const built = rig()
      const report = await reportOnSession(built.surface, view(entry.over))
      expect(report.reasons[0]?.why).toBe(entry.leads)
      expect(report.verdict.startsWith(entry.opening)).toBe(true)
    })
  }

  it('agrees about a looping session, which outranks the files it has not written', async () => {
    const built = rig({
      events: Array.from({ length: 12 }, (_unused, index) => ({
        at: 1_000 + index,
        name: 'Bash',
        failed: true,
      })),
    })
    const report = await reportOnSession(built.surface, view())
    expect(report.progress.verdict).toBe('looping')
    expect(report.reasons[0].why).toBe('looping')
    expect(report.verdict.startsWith('Looks stuck')).toBe(true)
  })
})
