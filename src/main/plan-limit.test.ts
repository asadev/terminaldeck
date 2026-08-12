import type { IpcMain } from 'electron'
import { describe, expect, it } from 'vitest'
import {
  dropPlanSession,
  identifyLimit,
  isLimitLabel,
  notePlanOutput,
  parsePlanLimits,
  PlanLimitTracker,
  registerPlanLimitIpc,
  type PlanLimitSnapshot,
  type RefreshResult,
} from './plan-limit'

/* ------------------------------------------------------------------ the IPC */

interface Pushed {
  id: string
  available: boolean
  reason: string | null
}

/** A window that records what was pushed to it. */
function fakeContents(sink: Pushed[] = []): unknown {
  return {
    isDestroyed: () => false,
    once: () => {},
    send: (_channel: string, id: string, snapshot: PlanLimitSnapshot) => {
      sink.push({ id, available: snapshot.available, reason: snapshot.reason })
    },
  }
}

/** Register the handlers against a fake `ipcMain` and hand back an `invoke`. */
function wire(write?: (sessionId: string, data: string) => void): {
  invoke: (channel: string, sender: unknown, ...args: unknown[]) => unknown
} {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  registerPlanLimitIpc(
    {
      handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
        handlers.set(channel, fn)
      },
      on: () => {},
    } as unknown as IpcMain,
    write ? { write } : {},
  )
  return {
    invoke: (channel: string, sender: unknown, ...args: unknown[]): unknown => {
      const fn = handlers.get(channel)
      if (!fn) throw new Error(`no handler for ${channel}`)
      return fn({ sender }, ...args)
    },
  }
}

/** Feed a fixture in the way a PTY does — a TUI ends its lines with CRLF. */
function feed(sessionId: string, text: string): void {
  notePlanOutput(sessionId, text.replace(/\n/g, '\r\n'))
}

/** Longer than the module's own idle gate before it will type into a session. */
function idleFor(ms = 1100): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

/**
 * The fixtures below are transcribed from a real Claude Code 2.1.228 session on
 * this machine — a PTY was spawned, `/usage` was typed into it, and the headless
 * terminal's viewport was dumped. Spacing, the bar glyphs and the parenthesised
 * timezone are all as the CLI drew them.
 */
const USAGE_PANEL = `
 ▐▛███▜▌   Claude Code v2.1.228
▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
   Settings  Status   Config   Usage   Stats

   Session

   Total cost:            $0.0000
   Total duration (API):  0s

   Current session
   ██▌                                                5% used
   Resets 4am (Asia/Dubai)

   Current week (all models)
   ████████████████████████████████████████           80% used
   Resets Aug 14 at 2pm (Asia/Dubai)
   +50% weekly limits promo through Aug 19 · clau.de/cc-50-promo

   Current week (Fable)
   ██████████████████████████████████████████████████ 100% used
   Resets Aug 14 at 2pm (Asia/Dubai)

   What's contributing to your limits usage?
`

/** The ordinary idle screen from the same capture — nothing to report. */
const IDLE_SCREEN = `
 ▐▛███▜▌   Claude Code v2.1.228
▝▜█████▛▘  Opus 5 (1M context) with xhigh effort · Claude Max
  ▘▘ ▝▝    ~/Projects/terminaldeck

──────────────────────────────────────────────────────────────────────────────
❯
──────────────────────────────────────────────────────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)
`

describe('reading the /usage panel', () => {
  const parsed = parsePlanLimits(USAGE_PANEL)

  it('finds every limit the panel lists', () => {
    expect(parsed?.source).toBe('usage-panel')
    expect(parsed?.limits.map((limit) => limit.id)).toEqual(['session', 'week', 'week:fable'])
  })

  it('keeps the percentages and the CLI\'s own reset wording', () => {
    expect(parsed?.limits[0]).toEqual({
      id: 'session',
      label: 'Current session',
      scope: 'session',
      percent: 5,
      resetsAt: '4am (Asia/Dubai)',
    })
    expect(parsed?.limits[1].percent).toBe(80)
    expect(parsed?.limits[1].resetsAt).toBe('Aug 14 at 2pm (Asia/Dubai)')
  })

  it('reads an exhausted limit as 100, not as a rounding artefact', () => {
    expect(parsed?.limits[2]).toMatchObject({ label: 'Current week (Fable)', percent: 100 })
  })

  it('does not let the promo line become a reset time', () => {
    expect(parsed?.limits.some((limit) => limit.resetsAt?.includes('promo'))).toBe(false)
  })
})

describe('reading a warning line', () => {
  it('parses the percent, the limit and the reset out of one sentence', () => {
    const parsed = parsePlanLimits("You've used 85% of your weekly limit · resets Aug 14 at 2pm")
    expect(parsed).toEqual({
      source: 'warning',
      message: "You've used 85% of your weekly limit · resets Aug 14 at 2pm",
      limits: [
        {
          id: 'week',
          label: 'weekly limit',
          scope: 'week',
          percent: 85,
          resetsAt: 'Aug 14 at 2pm',
        },
      ],
    })
  })

  it('reports a named limit with no number rather than inventing one', () => {
    const parsed = parsePlanLimits('⚠ Approaching Opus limit')
    expect(parsed?.limits[0]).toMatchObject({ id: 'week:opus', percent: null })
  })

  it('handles a typographic apostrophe, which is what the CLI actually prints', () => {
    const parsed = parsePlanLimits('You’ve used 92% of your session limit')
    expect(parsed?.limits[0]).toMatchObject({ id: 'session', percent: 92, resetsAt: null })
  })

  it('takes the newest line when the screen holds two', () => {
    const screen = ["You've used 40% of your weekly limit", "You've used 85% of your weekly limit"].join('\n')
    expect(parsePlanLimits(screen)?.limits[0].percent).toBe(85)
  })
})

describe('not mistaking agent output for a plan reading', () => {
  it('reports nothing on an ordinary screen', () => {
    expect(parsePlanLimits(IDLE_SCREEN)).toBeNull()
  })

  it('ignores a limit the agent is talking about', () => {
    // A terminal shows whatever the agent writes. Quoting this back as a
    // subscription reading is the failure this guard exists for.
    expect(parsePlanLimits("You've hit your retry limit — backing off")).toBeNull()
    expect(parsePlanLimits('Approaching the GitHub API rate limit')).toBeNull()
  })

  it('accepts only labels that name a real limit window', () => {
    expect(isLimitLabel('weekly limit')).toBe(true)
    expect(isLimitLabel('Opus limit')).toBe(true)
    expect(isLimitLabel('retry limit')).toBe(false)
  })
})

describe('naming limits consistently', () => {
  it('lands the panel and warning spellings of one limit on one key', () => {
    expect(identifyLimit('week all models').id).toBe(identifyLimit('weekly limit').id)
    expect(identifyLimit('session').id).toBe(identifyLimit('session limit').id)
    expect(identifyLimit('week Opus').id).toBe(identifyLimit('Opus limit').id)
  })
})

describe('the tracker', () => {
  it('reads limits off a repainted screen and keeps them when the panel closes', async () => {
    const seen: number[] = []
    const tracker = new PlanLimitTracker('s1', (snapshot) => seen.push(snapshot.limits.length), 80, 24)

    // Written the way a TUI writes: the bar and the number arrive separately,
    // and only the screen puts them on one line.
    tracker.push('Current week (all models)\r\n')
    tracker.push('████████████████')
    tracker.push('           80% used\r\n')
    tracker.push('Resets Aug 14 at 2pm (Asia/Dubai)\r\n')
    await new Promise((resolve) => setTimeout(resolve, 0))

    expect(tracker.capture()).toBe(true)
    expect(tracker.current.available).toBe(true)
    expect(tracker.current.limits[0]).toMatchObject({ id: 'week', percent: 80 })
    expect(seen).toEqual([1])

    // The panel is closed most of the time. Its absence is not news.
    tracker.push('\u001b[2J\u001b[H❯ \r\n')
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(tracker.capture()).toBe(false)
    expect(tracker.current.limits[0]).toMatchObject({ percent: 80 })
    expect(seen).toEqual([1])

    tracker.dispose()
  })

  it('tells a watcher its reading is over instead of dropping it silently', () => {
    // Nine sessions against a ceiling of eight: the evicted one must be told,
    // or its strip keeps showing a number nothing will ever update again.
    const seen: Array<{ id: string; available: boolean; reason: string | null }> = []
    const contents = fakeContents(seen)
    const { invoke } = wire()
    for (let i = 0; i < 9; i += 1) invoke('plan:watch', contents, `evict-${i}`)

    expect(seen).toEqual([
      { id: 'evict-0', available: false, reason: expect.stringContaining('released to make room') },
    ])
    for (let i = 0; i < 9; i += 1) dropPlanSession(`evict-${i}`)
  })

  it('knows when the prompt box is empty, which is when it is safe to type', async () => {
    const tracker = new PlanLimitTracker('s2', () => {}, 80, 24)
    tracker.push('❯ \r\n')
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(tracker.promptIsEmpty()).toBe(true)

    tracker.push('\u001b[2J\u001b[H❯ fix the b\r\n')
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(tracker.promptIsEmpty()).toBe(false)
    tracker.dispose()
  })
})

/**
 * The Check button, end to end through the IPC it actually calls.
 *
 * The button's whole claim is "types /usage into this session, reads the panel,
 * closes it again". These drive `plan:refresh` against a fake `ipcMain` and a
 * recording `write`, so what reaches the PTY — and what does not, when a gate
 * refuses — is asserted rather than assumed.
 */
describe('running /usage on request', () => {
  /** Escape — what a person presses to close the panel. */
  const ESC = String.fromCharCode(27)

  it('types the command, reads the panel it draws and closes it with Esc', async () => {
    const wrote: string[] = []
    const { invoke } = wire((id, data) => {
      wrote.push(data)
      // The CLI's answer to `/usage` is to draw its panel.
      if (data.includes('/usage')) feed(id, USAGE_PANEL)
    })
    invoke('plan:watch', fakeContents(), 'run-1')
    feed('run-1', IDLE_SCREEN)
    await idleFor()

    const result = (await invoke('plan:refresh', fakeContents(), 'run-1')) as RefreshResult
    expect(result.ok).toBe(true)
    expect(result.snapshot.source).toBe('usage-panel')
    expect(result.snapshot.limits.map((limit) => limit.id)).toEqual(['session', 'week', 'week:fable'])
    expect(result.snapshot.limits[1]).toMatchObject({ percent: 80, resetsAt: 'Aug 14 at 2pm (Asia/Dubai)' })
    // Exactly the two keystrokes it says it sends, in that order.
    expect(wrote).toEqual(['/usage\r', ESC])
    dropPlanSession('run-1')
  })

  it('types nothing into a session that is mid-answer', async () => {
    const wrote: string[] = []
    const { invoke } = wire((_id, data) => wrote.push(data))
    invoke('plan:watch', fakeContents(), 'busy-1')
    feed('busy-1', IDLE_SCREEN) // output *now* — the session is not settled

    const result = (await invoke('plan:refresh', fakeContents(), 'busy-1')) as RefreshResult
    expect(result).toMatchObject({ ok: false, reason: 'busy' })
    expect(wrote).toEqual([])
    dropPlanSession('busy-1')
  })

  it('types nothing when the prompt box is not empty', async () => {
    const wrote: string[] = []
    const { invoke } = wire((_id, data) => wrote.push(data))
    invoke('plan:watch', fakeContents(), 'typing-1')
    feed('typing-1', IDLE_SCREEN.replace('❯', '❯ the thing I was already typing'))
    await idleFor()

    const result = (await invoke('plan:refresh', fakeContents(), 'typing-1')) as RefreshResult
    expect(result).toMatchObject({ ok: false, reason: 'prompt-busy' })
    expect(wrote).toEqual([])
    dropPlanSession('typing-1')
  })

  it('says it is unwired rather than appearing to run', async () => {
    const { invoke } = wire()
    invoke('plan:watch', fakeContents(), 'unwired-1')
    const result = (await invoke('plan:refresh', fakeContents(), 'unwired-1')) as RefreshResult
    expect(result).toMatchObject({ ok: false, reason: 'unwired' })
    dropPlanSession('unwired-1')
  })

  it('says so when the session is not being watched at all', async () => {
    const { invoke } = wire(() => {})
    const result = (await invoke('plan:refresh', fakeContents(), 'never-watched')) as RefreshResult
    expect(result).toMatchObject({ ok: false, reason: 'not-watching' })
    expect(result.snapshot.available).toBe(false)
  })
})
