import type { IpcMain } from 'electron'
import { describe, expect, it } from 'vitest'
import {
  dropPlanSession,
  identifyLimit,
  isLimitLabel,
  notePlanOutput,
  parsePlanLimits,
  planBilling,
  planSnapshot,
  PlanLimitTracker,
  readClaudeBilling,
  registerPlanLimitIpc,
  watchPlanSnapshots,
  type PlanLimitSnapshot,
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

/**
 * Register the handlers against a fake `ipcMain` and hand back an `invoke`.
 *
 * It takes nothing, and that is the shape of the 2026-08-18 change rather than
 * a tidy-up. This used to be handed a `write`, a set of shortened timings and an
 * account memory, because `plan:refresh` typed `/usage` into a session and every
 * one of those existed to make that testable — what reached the PTY, how long a
 * panel got to appear, whether a login was asked twice. None of it exists now:
 * this module reads screens and writes to nothing. See `usage-probe.ts` and
 * `usage-ipc.test.ts` for where the fetching went and what it costs.
 */
function wire(): {
  invoke: (channel: string, sender: unknown, ...args: unknown[]) => unknown
} {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  registerPlanLimitIpc({
    handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
      handlers.set(channel, fn)
    },
    on: () => {},
  } as unknown as IpcMain)
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
    await tracker.flush()

    expect(tracker.capture()).toBe(true)
    expect(tracker.current.available).toBe(true)
    expect(tracker.current.limits[0]).toMatchObject({ id: 'week', percent: 80 })
    expect(seen).toEqual([1])

    // The panel is closed most of the time. Its absence is not news.
    tracker.push('\u001b[2J\u001b[H❯ \r\n')
    await tracker.flush()
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

})

/**
 * How old a reading is, as opposed to when this app last looked at it.
 *
 * The `/usage` panel stays on screen until it is dismissed, so re-reading the
 * viewport every 600 ms would otherwise re-stamp an hour-old figure as current.
 * That is the exact shape of the bug that ruled out `~/.claude.json` as a
 * source, and it is worth a test that fails if someone collapses the two
 * timestamps back into one.
 */
describe('how old a reading is', () => {
  it('keeps the first-seen time while the numbers on screen do not change', async () => {
    const tracker = new PlanLimitTracker('age-1', () => {}, 80, 24)
    tracker.push('Current session\r\n██▌   5% used\r\nResets 4am (Asia/Dubai)\r\n')
    await tracker.flush()

    tracker.capture(1_000)
    expect(tracker.current.firstSeenAt).toBe(1_000)

    // Read again much later with the same panel still up. This app looked
    // again; the CLI did not say anything again.
    tracker.capture(3_600_000)
    expect(tracker.current.capturedAt).toBe(3_600_000)
    expect(tracker.current.firstSeenAt).toBe(1_000)
    tracker.dispose()
  })

  it('moves the first-seen time when the number itself changes', async () => {
    const tracker = new PlanLimitTracker('age-2', () => {}, 80, 24)
    tracker.push('Current session\r\n██▌   5% used\r\n')
    await tracker.flush()
    tracker.capture(1_000)

    tracker.push('\u001b[2J\u001b[HCurrent session\r\n████   9% used\r\n')
    await tracker.flush()
    tracker.capture(2_000)
    expect(tracker.current.firstSeenAt).toBe(2_000)
    tracker.dispose()
  })

  it('treats a reading it just asked for as fresh even when it repeats', async () => {
    const tracker = new PlanLimitTracker('age-3', () => {}, 80, 24)
    tracker.push('Current session\r\n██▌   5% used\r\n')
    await tracker.flush()
    tracker.capture(1_000)
    // What `refresh` does after typing /usage: the CLI has just answered, so
    // the same numbers are a fresh answer rather than a leftover panel.
    tracker.capture(9_000, true)
    expect(tracker.current.firstSeenAt).toBe(9_000)
    tracker.dispose()
  })
})

/**
 * The reading as session state, not as a thing the chat view owns.
 *
 * The window chrome will draw this for a session that has no chat view open,
 * and the usage aggregator folds it in with Codex's numbers inside the main
 * process. Both need the same subscription a window gets, without a window.
 */
describe('watching from inside the main process', () => {
  it('hands over the current reading and then every change', async () => {
    const seen: PlanLimitSnapshot[] = []
    const watch = watchPlanSnapshots('inproc-1', (snapshot) => seen.push(snapshot))
    expect(watch.snapshot.available).toBe(false)
    expect(watch.snapshot.reason).toContain('has not printed')

    feed('inproc-1', 'Current week (all models)\n████   80% used\nResets Aug 14 at 2pm\n')
    await new Promise((resolve) => setTimeout(resolve, 800))

    expect(seen.at(-1)?.limits[0]).toMatchObject({ id: 'week', percent: 80 })
    watch.stop()
    dropPlanSession('inproc-1')
  })

  it('does not report a session that has never printed anything as unwatched', () => {
    // Two different sentences: nobody is looking, versus nothing was said. The
    // first is fixed by watching, the second by running /usage.
    expect(planSnapshot('nobody-home').reason).toContain('No live session is being watched')
    const watch = watchPlanSnapshots('inproc-2', () => {})
    expect(planSnapshot('inproc-2').reason).toContain('has not printed')
    watch.stop()
  })

  it('keeps the tracker alive for a listener after the last window lets go', async () => {
    // A local wiring, because this is the one test that needs `plan:unwatch` —
    // the shared `wire` above only captures the invoke handlers.
    const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
    const sends = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
    registerPlanLimitIpc({
      handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
        handlers.set(channel, fn)
      },
      on: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
        sends.set(channel, fn)
      },
    } as unknown as IpcMain)

    const seen: PlanLimitSnapshot[] = []
    const contents = fakeContents()
    handlers.get('plan:watch')?.({ sender: contents }, 'inproc-3')
    const watch = watchPlanSnapshots('inproc-3', (snapshot) => seen.push(snapshot))

    // The window closes its tab. The chrome is still watching, so the shadow
    // terminal must survive — dropping it here is how the bar would freeze.
    sends.get('plan:unwatch')?.({ sender: contents }, 'inproc-3')
    feed('inproc-3', 'Current session\n██   7% used\n')
    await new Promise((resolve) => setTimeout(resolve, 800))
    expect(seen.at(-1)?.limits[0]).toMatchObject({ id: 'session', percent: 7 })

    watch.stop()
    // Stopping the last listener releases it for real.
    expect(planSnapshot('inproc-3').reason).toContain('No live session is being watched')
  })
})

/* -------------------------------------------------------------------------- */
/* The account, not the session                                                */
/* -------------------------------------------------------------------------- */

/**
 * Claude Code's own welcome banner, which names the billing before anybody has
 * asked it anything.
 *
 * Both of these are real. The first was captured on this Mac on 2026-08-18 by
 * spawning `claude` 2.1.234 through node-pty into a headless terminal and
 * dumping the viewport; the second is the line off Asad's Windows recording,
 * quoted in `SessionControls.tsx`, from a login the CLI labels `Claude API`.
 */
const BANNER_MAX = '│      Opus 5 with xhigh effort · Claude Max ·       │'
const BANNER_API = 'Claude Code v2.1.224 · Opus 5 with xhigh effort · Claude API'
/** The same clause at a width narrow enough that the CLI truncates the effort. */
const BANNER_NARROW = '│   Opus 5 (1M context) with xhig… · Claude Max ·    │'

describe('reading the billing off the banner', () => {
  it('tells a subscription from a metered account', () => {
    expect(readClaudeBilling(BANNER_MAX)).toBe('subscription')
    expect(readClaudeBilling(BANNER_NARROW)).toBe('subscription')
    expect(readClaudeBilling(BANNER_API)).toBe('api')
    // Everything that is not a subscription is the same answer here, because
    // none of them has a rolling window for the CLI to draw.
    expect(readClaudeBilling('  Opus 5 with xhigh effort · Bedrock ·')).toBe('api')
    expect(readClaudeBilling('  Opus 5 with xhigh effort · API Usage Billing')).toBe('api')
  })

  it('says nothing rather than guessing at a truncated label', () => {
    // A narrow enough window truncates the billing itself. Half a word is not
    // an answer, and the fallback for "not known" is to ask once and remember —
    // which is cheap. The fallback for a wrong guess is a bar asserting
    // something false about how somebody is billed.
    expect(readClaudeBilling('│ Opus 5 with xhi… · Claude M… │')).toBeNull()
    expect(readClaudeBilling('')).toBeNull()
  })

  it('does not read a banner out of ordinary conversation', () => {
    // The screen this parses is a terminal, and an agent can write anything in
    // it. The anchor is the clause the CLI composes itself.
    expect(readClaudeBilling('I would go with more effort here. Claude API is fine.')).toBeNull()
    expect(readClaudeBilling('Claude Max is the plan you want')).toBeNull()
  })

  it('finds it on the real idle screen this suite already had', () => {
    // The fixture at the top of this file was captured before any of this
    // existed, and the banner has been sitting in it the whole time.
    expect(readClaudeBilling(IDLE_SCREEN)).toBe('subscription')
  })

  it('reports a watched session’s billing, and says nothing about one it has not seen', async () => {
    /*
     * The one thing this module still tells the rest of the app about *cost*
     * rather than about numbers, and it is the cheapest gate in the feature:
     * `refreshUsage` in `usage-ipc.ts` reads this before deciding whether to
     * start a `claude` at all, so an API-billed login is answered from a line
     * the CLI printed of its own accord instead of from a four-second process.
     *
     * The null case is the half that matters. "No banner has been seen" is not
     * "no subscription", and a caller that read it as one would switch the
     * feature off on a perfectly good login.
     */
    const { invoke } = wire()
    expect(planBilling('billing-1')).toBeNull()

    invoke('plan:watch', fakeContents(), 'billing-1')
    expect(planBilling('billing-1')).toBeNull()

    feed('billing-1', `${BANNER_API}\n❯\n`)
    // `push` hands the bytes to xterm, which parses them on its own schedule —
    // "I fed four lines in" and "the screen shows four lines" are different
    // moments and nothing outside the tracker can tell them apart. Waiting a
    // macrotask is what every other test in this file does for the same reason.
    await new Promise((resolve) => setTimeout(resolve, 30))
    expect(planBilling('billing-1')).toBe('api')

    dropPlanSession('billing-1')
    expect(planBilling('billing-1')).toBeNull()
  })
})
