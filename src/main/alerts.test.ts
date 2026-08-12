import { chmod, mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import {
  CONTEXT_CRITICAL_PERCENT,
  CONTEXT_WARNING_PERCENT,
  contextUsage,
  PRE_CONTEXT_BLOAT_PERCENT,
} from './cost'
import { encodeProjectPath } from './transcript'
import {
  BLOCKED_CRITICAL_MS,
  BLOCKED_WARNING_MS,
  blockedAlerts,
  collectAlertInput,
  contextAlerts,
  deriveAlerts,
  DIRTY_TREE_SESSION_STREAK,
  dirtyTreeAlerts,
  EXPENSIVE_MIN_SAMPLE,
  EXPENSIVE_MIN_USD,
  EXPENSIVE_MULTIPLE,
  expensiveSessionAlerts,
  formatDuration,
  groupBySeverity,
  median,
  providerAlerts,
  type AlertInput,
  type AlertSession,
} from './alerts'

const NOW = Date.parse('2026-08-12T12:00:00.000Z')
const MINUTE = 60_000
const WINDOW = 200_000

/** An input with nothing in it — the state a folder added a second ago is in. */
function emptyInput(overrides: Partial<AlertInput> = {}): AlertInput {
  return {
    projectPath: '/Users/apple/Projects/pawl',
    now: NOW,
    sessions: [],
    providersInUse: [],
    providersInstalled: { claude: true, codex: false, gemini: false, shell: true },
    git: null,
    ...overrides,
  }
}

function session(overrides: Partial<AlertSession> & { sessionId: string }): AlertSession {
  return {
    transcriptPath: `/tmp/${overrides.sessionId}.jsonl`,
    context: null,
    preContextTokens: 0,
    requests: 10,
    costUsd: null,
    startedAt: NOW - 60 * MINUTE,
    lastActivityAt: NOW - 5 * MINUTE,
    status: null,
    ...overrides,
  }
}

/** A session sitting at `percent` of its window, built through cost.ts's own maths. */
function atContext(sessionId: string, percent: number, overrides: Partial<AlertSession> = {}): AlertSession {
  const tokens = Math.round((percent / 100) * WINDOW)
  return session({
    sessionId,
    context: contextUsage(tokens, 'claude-opus-5', WINDOW),
    ...overrides,
  })
}

/* ------------------------------------------------------- the quiet invariant -- */

describe('a brand-new project', () => {
  it('produces no alerts at all', () => {
    const report = deriveAlerts(emptyInput())
    expect(report.alerts).toEqual([])
    expect(report.worst).toBeNull()
    expect(report.counts).toEqual({ critical: 0, warning: 0, info: 0 })
  })

  it('stays quiet with a clean repo and no sessions', () => {
    const report = deriveAlerts(
      emptyInput({ git: { repo: true, dirty: false, changedFiles: 0, lastChangeAt: null } }),
    )
    expect(report.alerts).toEqual([])
  })

  it('stays quiet when a transcript exists but nothing ever ran in it', () => {
    // Claude Code opens a file the moment a session starts; zero requests means
    // the session was closed without asking anything.
    const report = deriveAlerts(
      emptyInput({
        sessions: [session({ sessionId: 'empty', requests: 0, costUsd: 0, preContextTokens: 90_000 })],
      }),
    )
    expect(report.alerts).toEqual([])
  })

  it('does not complain about uninstalled CLIs the project never asked for', () => {
    // codex and gemini are both missing here, and that is nobody's problem.
    const report = deriveAlerts(emptyInput({ providersInUse: [] }))
    expect(report.alerts).toEqual([])
  })

  it('does not flag a dirty tree on its own', () => {
    // A folder cloned five minutes ago is dirty and has run nothing. Alerting
    // on that trains the user to ignore the panel on day one.
    const report = deriveAlerts(
      emptyInput({
        git: { repo: true, dirty: true, changedFiles: 12, lastChangeAt: NOW - MINUTE },
      }),
    )
    expect(report.alerts).toEqual([])
  })
})

/* ------------------------------------------------------------------ helpers -- */

describe('median', () => {
  it('averages the middle pair on an even sample', () => {
    expect(median([1, 2, 3, 4])).toBe(2.5)
  })

  it('takes the middle of an odd sample regardless of input order', () => {
    expect(median([9, 1, 5])).toBe(5)
  })

  it('is zero for no sample', () => {
    expect(median([])).toBe(0)
  })
})

describe('formatDuration', () => {
  it('never says "0 minutes"', () => {
    expect(formatDuration(20_000)).toBe('1 minute')
  })

  it('steps up to hours and days', () => {
    expect(formatDuration(90 * MINUTE)).toBe('2 hours')
    expect(formatDuration(50 * 60 * MINUTE)).toBe('2 days')
  })
})

/* ------------------------------------------------------------ context bloat -- */

describe('contextAlerts', () => {
  it('is silent below cost.ts\'s warning threshold', () => {
    const alerts = contextAlerts(
      emptyInput({ sessions: [atContext('s1', CONTEXT_WARNING_PERCENT - 1)] }),
    )
    expect(alerts).toEqual([])
  })

  it('warns at the threshold and escalates at the critical one', () => {
    const warn = contextAlerts(emptyInput({ sessions: [atContext('s1', CONTEXT_WARNING_PERCENT)] }))
    expect(warn.map((alert) => alert.severity)).toEqual(['warning'])

    const critical = contextAlerts(
      emptyInput({ sessions: [atContext('s1', CONTEXT_CRITICAL_PERCENT)] }),
    )
    expect(critical.map((alert) => alert.severity)).toEqual(['critical'])
    expect(critical[0].action?.kind).toBe('compact-session')
  })

  it('reports only the most recent session, not every session in history', () => {
    const alerts = contextAlerts(
      emptyInput({
        sessions: [
          atContext('old', 95, { lastActivityAt: NOW - 10 * 24 * 60 * MINUTE }),
          atContext('new', 95, { lastActivityAt: NOW - MINUTE }),
        ],
      }),
    )
    expect(alerts).toHaveLength(1)
    expect(alerts[0].sessionId).toBe('new')
  })

  it('flags an oversized fixed prefix separately from the live window', () => {
    const preTokens = Math.round(((PRE_CONTEXT_BLOAT_PERCENT + 1) / 100) * WINDOW)
    const alerts = contextAlerts(
      emptyInput({ sessions: [atContext('s1', 20, { preContextTokens: preTokens })] }),
    )
    expect(alerts.map((alert) => alert.kind)).toEqual(['pre-context-bloat'])
  })

  it('does not flag a prefix that is a normal share of the window', () => {
    const preTokens = Math.round(((PRE_CONTEXT_BLOAT_PERCENT - 5) / 100) * WINDOW)
    const alerts = contextAlerts(
      emptyInput({ sessions: [atContext('s1', 20, { preContextTokens: preTokens })] }),
    )
    expect(alerts).toEqual([])
  })
})

/* --------------------------------------------------------------- blocked -- */

describe('blockedAlerts', () => {
  it('ignores a session that only just asked', () => {
    const alerts = blockedAlerts(
      emptyInput({
        sessions: [session({ sessionId: 's1', status: 'input', statusSince: NOW - MINUTE })],
      }),
    )
    expect(alerts).toEqual([])
  })

  it('warns once the wait passes the threshold, and escalates later', () => {
    const warn = blockedAlerts(
      emptyInput({
        sessions: [session({ sessionId: 's1', status: 'input', statusSince: NOW - BLOCKED_WARNING_MS })],
      }),
    )
    expect(warn[0].severity).toBe('warning')

    const critical = blockedAlerts(
      emptyInput({
        sessions: [session({ sessionId: 's1', status: 'input', statusSince: NOW - BLOCKED_CRITICAL_MS })],
      }),
    )
    expect(critical[0].severity).toBe('critical')
    expect(critical[0].action?.target).toBe('s1')
  })

  it('does not treat a ready prompt as blocked', () => {
    // session-activity.ts calls an empty prompt `waiting` and an unanswered
    // question `input`. Only the second is stuck; the first is every idle tab.
    for (const status of ['waiting', 'idle', 'working', 'completed', 'exited'] as const) {
      const alerts = blockedAlerts(
        emptyInput({
          sessions: [session({ sessionId: 's1', status, statusSince: NOW - 5 * BLOCKED_CRITICAL_MS })],
        }),
      )
      expect(alerts, status).toEqual([])
    }
  })

  it('never fires for history, which has no live status', () => {
    const alerts = blockedAlerts(
      emptyInput({
        sessions: [session({ sessionId: 's1', status: null, lastActivityAt: NOW - 200 * MINUTE })],
      }),
    )
    expect(alerts).toEqual([])
  })
})

/* ------------------------------------------------------------- providers -- */

describe('providerAlerts', () => {
  it('fires only for a provider this project actually uses', () => {
    const alerts = providerAlerts(emptyInput({ providersInUse: ['codex'] }))
    expect(alerts).toHaveLength(1)
    expect(alerts[0].severity).toBe('critical')
    expect(alerts[0].action?.target).toBe('codex')
  })

  it('says nothing about a provider in use that is installed', () => {
    expect(providerAlerts(emptyInput({ providersInUse: ['claude'] }))).toEqual([])
  })

  it('never fires for the shell, which is always present', () => {
    expect(providerAlerts(emptyInput({ providersInUse: ['shell'] }))).toEqual([])
  })

  it('stays quiet when detection itself failed rather than claiming everything is missing', () => {
    // `detectProviders` returning {} means "we could not look", not "nothing is
    // installed" — an empty map must not produce an alert per provider.
    const alerts = providerAlerts(
      emptyInput({ providersInUse: ['claude', 'codex'], providersInstalled: {} }),
    )
    expect(alerts).toEqual([])
  })

  it('reports each missing provider once even when several sessions use it', () => {
    const alerts = providerAlerts(emptyInput({ providersInUse: ['codex', 'codex', 'gemini'] }))
    expect(alerts.map((alert) => alert.id)).toEqual(['provider-missing:codex', 'provider-missing:gemini'])
  })

  it('ignores a provider id that is not in the table instead of throwing', () => {
    // Hardening rather than a reported crash: today `providersInstalled` is
    // only ever built by `detectProviders()`, whose keys all come from
    // `PROVIDERS`, so an unrecognised id is filtered out one line earlier by
    // the `!== false` check. The moment anything else fills that map — a
    // cached copy on disk, a provider dropped from the table between releases —
    // the blind `PROVIDERS[provider]` lookup throws
    // `Cannot read properties of undefined (reading 'label')` out of a pure
    // function, through `deriveAlerts`, and takes the whole report with it.
    // This input is exactly that shape.
    const input = emptyInput({
      providersInUse: ['ollama' as never, 'codex'],
      providersInstalled: { ollama: false, codex: false } as AlertInput['providersInstalled'],
    })
    expect(() => providerAlerts(input)).not.toThrow()
    expect(providerAlerts(input).map((alert) => alert.id)).toEqual(['provider-missing:codex'])
    // And the whole report still comes back rather than rejecting.
    expect(() => deriveAlerts(input)).not.toThrow()
  })
})

/* --------------------------------------------------------------- spending -- */

describe('expensiveSessionAlerts', () => {
  function pricedSessions(costs: number[]): AlertSession[] {
    return costs.map((costUsd, index) =>
      session({ sessionId: `s${index}`, costUsd, lastActivityAt: NOW - index * MINUTE }),
    )
  }

  it('needs a real sample before a median means anything', () => {
    const costs = Array.from({ length: EXPENSIVE_MIN_SAMPLE - 1 }, () => 1)
    costs[0] = 100
    expect(expensiveSessionAlerts(emptyInput({ sessions: pricedSessions(costs) }))).toEqual([])
  })

  it('fires when one session is well past the project median', () => {
    const alerts = expensiveSessionAlerts(
      emptyInput({ sessions: pricedSessions([1, 1, 1.2, 0.9, 1.1, 12]) }),
    )
    expect(alerts).toHaveLength(1)
    expect(alerts[0].kind).toBe('expensive-session')
    expect(alerts[0].sessionId).toBe('s5')
  })

  it('does not fire on a ratio alone when the amounts are trivial', () => {
    // Median $0.004, worst $0.05 — twelve times the median and not worth a word.
    const alerts = expensiveSessionAlerts(
      emptyInput({ sessions: pricedSessions([0.004, 0.004, 0.005, 0.003, 0.004, 0.05]) }),
    )
    expect(alerts).toEqual([])
  })

  it('does not fire just under the multiple', () => {
    const justUnder = EXPENSIVE_MIN_USD * (EXPENSIVE_MULTIPLE - 0.5)
    const alerts = expensiveSessionAlerts(
      emptyInput({ sessions: pricedSessions([1, 1, 1, 1, 1, justUnder]) }),
    )
    expect(alerts).toEqual([])
  })

  it('reports only the worst offender rather than one alert per session', () => {
    const alerts = expensiveSessionAlerts(
      emptyInput({ sessions: pricedSessions([1, 1, 1, 1, 1, 8, 20, 15]) }),
    )
    expect(alerts).toHaveLength(1)
    expect(alerts[0].detail).toContain('$20')
  })

  it('never rises to critical — money already spent is not an emergency', () => {
    const alerts = expensiveSessionAlerts(
      emptyInput({ sessions: pricedSessions([1, 1, 1, 1, 1, 500]) }),
    )
    expect(alerts[0].severity).not.toBe('critical')
  })

  it('ignores sessions with no published rate rather than counting them as free', () => {
    const sessions = [
      ...pricedSessions([2, 2, 2, 2, 2, 9]),
      session({ sessionId: 'unpriced', costUsd: null }),
    ]
    const alerts = expensiveSessionAlerts(emptyInput({ sessions }))
    // A null-cost session folded in as 0 would drag the median down and inflate
    // the ratio, so its absence from the sample is the thing being asserted.
    expect(alerts[0].detail).toContain('6 priced sessions')
  })
})

/* ------------------------------------------------------------ dirty tree -- */

describe('dirtyTreeAlerts', () => {
  const CHANGED_AT = NOW - 5 * 24 * 60 * MINUTE

  function sessionsStartedAfter(count: number): AlertSession[] {
    return Array.from({ length: count }, (_, index) =>
      session({ sessionId: `s${index}`, startedAt: CHANGED_AT + (index + 1) * 60 * MINUTE }),
    )
  }

  const dirty = { repo: true, dirty: true, changedFiles: 4, lastChangeAt: CHANGED_AT }

  it('says nothing about a folder that is not a repository', () => {
    const alerts = dirtyTreeAlerts(
      emptyInput({
        git: { repo: false, dirty: false, changedFiles: 0, lastChangeAt: null },
        sessions: sessionsStartedAfter(10),
      }),
    )
    expect(alerts).toEqual([])
  })

  it('says nothing about a clean tree', () => {
    const alerts = dirtyTreeAlerts(
      emptyInput({
        git: { repo: true, dirty: false, changedFiles: 0, lastChangeAt: CHANGED_AT },
        sessions: sessionsStartedAfter(10),
      }),
    )
    expect(alerts).toEqual([])
  })

  it('needs several sessions to have run on top of the changes', () => {
    const quiet = dirtyTreeAlerts(
      emptyInput({ git: dirty, sessions: sessionsStartedAfter(DIRTY_TREE_SESSION_STREAK - 1) }),
    )
    expect(quiet).toEqual([])

    const loud = dirtyTreeAlerts(
      emptyInput({ git: dirty, sessions: sessionsStartedAfter(DIRTY_TREE_SESSION_STREAK) }),
    )
    expect(loud).toHaveLength(1)
    expect(loud[0].action?.kind).toBe('open-git')
  })

  it('only counts sessions that started after the tree was last touched', () => {
    // Ten sessions, all of them older than the change: the work is new, not stale.
    const older = Array.from({ length: 10 }, (_, index) =>
      session({ sessionId: `old${index}`, startedAt: CHANGED_AT - (index + 1) * 60 * MINUTE }),
    )
    expect(dirtyTreeAlerts(emptyInput({ git: dirty, sessions: older }))).toEqual([])
  })

  it('escalates once the pile has been sitting there far longer', () => {
    const alerts = dirtyTreeAlerts(emptyInput({ git: dirty, sessions: sessionsStartedAfter(9) }))
    expect(alerts[0].severity).toBe('warning')
  })
})

/* ------------------------------------------------------------ the report -- */

describe('deriveAlerts', () => {
  const input = emptyInput({
    providersInUse: ['codex'],
    sessions: [
      atContext('hot', 95, { lastActivityAt: NOW - MINUTE, costUsd: 2 }),
      session({ sessionId: 'stuck', status: 'input', statusSince: NOW - BLOCKED_WARNING_MS - MINUTE }),
    ],
  })

  it('orders by severity, then by how recent the evidence is', () => {
    const report = deriveAlerts(input)
    const severities = report.alerts.map((alert) => alert.severity)
    expect(severities).toEqual([...severities].sort((a, b) => (a === b ? 0 : a === 'critical' ? -1 : 1)))
    expect(report.worst).toBe('critical')
  })

  it('counts every severity', () => {
    const report = deriveAlerts(input)
    const total = report.counts.critical + report.counts.warning + report.counts.info
    expect(total).toBe(report.alerts.length)
  })

  it('gives every alert a stable id across identical scans', () => {
    const first = deriveAlerts(input).alerts.map((alert) => alert.id)
    const second = deriveAlerts({ ...input, now: input.now + 1000 }).alerts.map((alert) => alert.id)
    expect(second).toEqual(first)
  })

  it('is pure — the same input twice gives the same report', () => {
    expect(deriveAlerts(input)).toEqual(deriveAlerts(input))
  })
})

/* --------------------------------------------------------------- gathering -- */

describe('collectAlertInput', () => {
  const temps: string[] = []

  afterAll(async () => {
    await Promise.all(
      temps.map(async (dir) => {
        // Chmod back first: a 000 file inside cannot be removed otherwise.
        await rm(dir, { recursive: true, force: true }).catch(() => undefined)
      }),
    )
  })

  async function configWith(
    project: string,
    files: Array<{ name: string; body: string; mode?: number }>,
  ): Promise<string> {
    const config = await mkdtemp(join(tmpdir(), 'pawl-alerts-'))
    temps.push(config)
    const dir = join(config, 'projects', encodeProjectPath(project))
    await mkdir(dir, { recursive: true })
    for (const file of files) {
      const path = join(dir, file.name)
      await writeFile(path, file.body, 'utf8')
      if (file.mode !== undefined) await chmod(path, file.mode)
    }
    return config
  }

  /** One request's worth of a real transcript line. */
  function usageLine(sessionId: string, cwd: string): string {
    return JSON.stringify({
      type: 'assistant',
      sessionId,
      cwd,
      requestId: `req-${sessionId}`,
      timestamp: '2026-08-10T09:00:00.000Z',
      message: {
        role: 'assistant',
        model: 'claude-opus-5',
        usage: { input_tokens: 100, output_tokens: 50 },
        content: [{ type: 'text', text: 'hello' }],
      },
    })
  }

  it('reads a project through the config dir it is given', async () => {
    const project = '/Users/apple/Projects/alerts-fixture'
    const config = await configWith(project, [
      { name: 'good.jsonl', body: usageLine('good', project) + '\n' },
    ])

    const input = await collectAlertInput(project, { configDir: config, now: () => NOW })
    expect(input.now).toBe(NOW)
    expect(input.sessions.map((session) => session.sessionId)).toContain('good')
  }, 30_000)

  it('skips a transcript it cannot read rather than losing the whole report', async () => {
    // Regression: a single EACCES under `~/.claude/projects` rejected the scan
    // outright, so one unreadable file meant the panel showed a raw errno in
    // place of every alert it had already gathered the inputs for.
    const project = '/Users/apple/Projects/alerts-unreadable'
    const config = await configWith(project, [
      { name: 'good.jsonl', body: usageLine('good', project) + '\n' },
      { name: 'locked.jsonl', body: usageLine('locked', project) + '\n', mode: 0o000 },
    ])

    const input = await collectAlertInput(project, { configDir: config, now: () => NOW })
    expect(input.sessions.map((session) => session.sessionId)).toContain('good')
    // The report still derives, which is the thing the user sees.
    expect(() => deriveAlerts(input)).not.toThrow()

    await chmod(join(config, 'projects', encodeProjectPath(project), 'locked.jsonl'), 0o644)
  }, 30_000)

  it('stays quiet for a project with no transcripts at all', async () => {
    const config = await mkdtemp(join(tmpdir(), 'pawl-alerts-'))
    temps.push(config)
    await mkdir(join(config, 'projects'), { recursive: true })

    const input = await collectAlertInput('/Users/apple/Projects/never-opened', {
      configDir: config,
      now: () => NOW,
    })
    expect(input.sessions).toEqual([])
    expect(deriveAlerts(input).alerts).toEqual([])
  }, 30_000)

  it('keeps a live session it cannot join to any transcript', async () => {
    const project = '/Users/apple/Projects/alerts-live'
    const config = await configWith(project, [])

    const input = await collectAlertInput(project, {
      configDir: config,
      now: () => NOW,
      liveSessions: () => [
        {
          sessionId: 'pty-uuid',
          cwd: project,
          status: 'input',
          statusSince: NOW - BLOCKED_CRITICAL_MS,
        },
      ],
    })
    // Live ids and transcript ids are different namespaces — see the comment in
    // `collectAlertInput`. The blocked rule is the one that wants these.
    expect(deriveAlerts(input).alerts.map((entry) => entry.kind)).toContain('session-blocked')
  }, 30_000)
})

describe('groupBySeverity', () => {
  it('drops empty groups and keeps critical first', () => {
    const groups = groupBySeverity(deriveAlerts(
      emptyInput({ providersInUse: ['codex'] }),
    ).alerts)
    expect(groups.map((group) => group.severity)).toEqual(['critical'])
  })

  it('returns nothing for a quiet project', () => {
    expect(groupBySeverity([])).toEqual([])
  })
})
