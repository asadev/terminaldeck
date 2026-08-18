import type { IpcMain } from 'electron'
import { describe, expect, it } from 'vitest'
import {
  dropPlanSession,
  identifyLimit,
  isLimitLabel,
  notePlanOutput,
  parsePlanLimits,
  planSnapshot,
  PlanLimitTracker,
  registerPlanLimitIpc,
  usagePanelOnScreen,
  usagePanelScanning,
  watchPlanSnapshots,
  type PlanLimitSnapshot,
  type RefreshResult,
  type RefreshTimings,
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
 * `timings` is the seam described on {@link RefreshTimings}: the rules being
 * proved below are measured in seconds and a suite that spent them for real
 * would be several minutes slower for nothing. Omitting it uses the app's own.
 */
function wire(
  write?: (sessionId: string, data: string) => void,
  timings?: RefreshTimings,
): {
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
    {
      ...(write ? { write } : {}),
      ...(timings ? { timings } : {}),
    },
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

  it('knows when the prompt box is empty, which is when it is safe to type', async () => {
    const tracker = new PlanLimitTracker('s2', () => {}, 80, 24)
    tracker.push('❯ \r\n')
    await tracker.flush()
    expect(tracker.promptIsEmpty()).toBe(true)

    tracker.push('\u001b[2J\u001b[H❯ fix the b\r\n')
    await tracker.flush()
    expect(tracker.promptIsEmpty()).toBe(false)
    tracker.dispose()
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
    registerPlanLimitIpc(
      {
        handle: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
          handlers.set(channel, fn)
        },
        on: (channel: string, fn: (event: unknown, ...args: unknown[]) => unknown) => {
          sends.set(channel, fn)
        },
      } as unknown as IpcMain,
      {},
    )

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

/**
 * The `/usage` panel of an account that has no subscription limits.
 *
 * Transcribed from a fifteen-second screen recording Asad sent from his Windows
 * machine on 2026-08-18, running Terminal Deck 0.4.0 against Claude Code
 * 2.1.224 under an account the CLI itself labels `Claude API`. Every line is
 * his, including the two dollar figures: the panel is complete, and there is no
 * `Current session` and no `Current week` anywhere between the cost block and
 * the contributors. An account billed through the API has no rolling
 * subscription window, so the CLI has nothing to draw there and draws nothing.
 *
 * There is no prompt glyph in it, deliberately. The panel takes the region the
 * prompt box occupies, which is what makes "the prompt is back" a sound test
 * for "the panel has gone".
 */
const PANEL_WITHOUT_LIMITS = `
   Settings  Status   Config   Usage   Stats

   Session

   Total cost:            $146.95
   Total duration (API):  5h 50m 42s
   Total duration (wall): 17h 23m 44s
   Total code changes:    2673 lines added, 15 lines removed
   Usage by model:
       claude-haiku-4-5:  134.2k input, 1.9k output, 0 cache read, 0 cache write, 6 web search ($0.2037)
        claude-opus-5:  9.5k input, 1.6m output, 129.0m cache read, 6.0m cache write ($146.75)

   What's contributing to your limits usage?
   Approximate, based on local sessions on this machine — does not include other devices or claude.ai

   Last 24h · these are independent characteristics of your usage, not a breakdown

   48% of your usage came from subagent-heavy sessions
    Each subagent runs its own requests. Be deliberate about spawning them — and
    consider configuring a cheaper model for simpler subagents.
`

/**
 * The same panel while it is still walking the transcript store.
 *
 * The two lines at the end are the CLI's own, and the second is what the first
 * theory about this bug turned on: while the scan runs, the panel offers Escape
 * as the way to cancel *the scan*, which made it look as though the app's one
 * Escape was being spent on the wrong thing. Driving the real CLI here refuted
 * that — see `closePanel` — but the state is real and has to be waited out
 * rather than read as an empty answer.
 */
const PANEL_SCANNING = `${PANEL_WITHOUT_LIMITS}
   Scanning local sessions…

   Esc to cancel
`

/** The panel with limits in it, drawn where the prompt box was. */
const PANEL_WITH_LIMITS = `
   Settings  Status   Config   Usage   Stats

   Session

   Total cost:            $0.0000

   Current session
   ██▌                                                5% used
   Resets 4am (Asia/Dubai)

   Current week (all models)
   ████████████████████████████████████████           80% used
   Resets Aug 14 at 2pm (Asia/Dubai)

   What's contributing to your limits usage?
`

describe('recognising the panel itself', () => {
  it('sees a panel that has no plan limits in it at all', () => {
    // The distinction the old code could not make: there is nothing to parse
    // here, and there is very much something on the screen.
    expect(parsePlanLimits(PANEL_WITHOUT_LIMITS)).toBeNull()
    expect(usagePanelOnScreen(PANEL_WITHOUT_LIMITS)).toBe(true)
  })

  it('does not mistake ordinary output for an open panel', () => {
    expect(usagePanelOnScreen(IDLE_SCREEN)).toBe(false)
    expect(usagePanelOnScreen('the settings status config usage stats are fine')).toBe(false)
  })

  it('tells a scan in progress from a panel that has finished', () => {
    expect(usagePanelScanning(PANEL_SCANNING)).toBe(true)
    expect(usagePanelScanning(PANEL_WITHOUT_LIMITS)).toBe(false)
    expect(usagePanelScanning(IDLE_SCREEN)).toBe(false)
  })
})

/**
 * Everything below drives the real `refresh` against a fake CLI, with the
 * timings shortened so that a five-second rule does not cost five seconds to
 * prove. The rules themselves are the app's.
 */
describe('never leaving a panel on somebody screen', () => {
  const ESC = String.fromCharCode(27)
  const FAST: RefreshTimings = {
    idleBeforeTyping: 120,
    panelAppears: 900,
    settledGrace: 500,
    scanCeiling: 2_500,
    closeSettle: 700,
  }

  /**
   * Repaint the session's whole screen, the way a TUI does.
   *
   * Clear-and-home before the text, because the thing being tested is whether
   * the panel is *on* the screen: appending it under the last one would leave
   * the prompt glyph from the idle screen visible above it, and the panel would
   * read as closed before anything had closed it. That is not a detail — the
   * one existing test in this file that types `/usage` passed for exactly that
   * reason and would have gone on passing with the close verification removed.
   */
  function paint(sessionId: string, text: string): void {
    feed(sessionId, `\u001b[2J\u001b[H${text}`)
  }

  it('reads the panel, then proves the panel went away', async () => {
    const wrote: string[] = []
    const { invoke } = wire((id, data) => {
      wrote.push(data)
      if (data.includes('/usage')) paint(id, PANEL_WITH_LIMITS)
      // A CLI that honours Escape, which is what a real one does: measured on a
      // real PTY here, one press closed the panel inside 103ms.
      if (data === ESC) paint(id, IDLE_SCREEN)
    }, FAST)
    invoke('plan:watch', fakeContents(), 'close-1')
    paint('close-1', IDLE_SCREEN)
    await idleFor(160)

    const result = (await invoke('plan:refresh', fakeContents(), 'close-1')) as RefreshResult
    expect(result).toMatchObject({ ok: true, reason: null, typed: true, residue: false })
    expect(result.snapshot.source).toBe('usage-panel')
    // One Escape, because one was enough. The second is an escalation, not a
    // habit.
    expect(wrote).toEqual(['/usage\r', ESC])
    dropPlanSession('close-1')
  })

  it('says so when the panel will not close, instead of walking away from it', async () => {
    const wrote: string[] = []
    // A CLI that ignores Escape entirely. Whether that is Windows conpty, an
    // older build, or a redraw racing the keystroke does not matter here: what
    // matters is that this app cannot report success and cannot fall silent.
    const { invoke } = wire((id, data) => {
      wrote.push(data)
      if (data.includes('/usage')) paint(id, PANEL_WITH_LIMITS)
    }, FAST)
    invoke('plan:watch', fakeContents(), 'stuck-1')
    paint('stuck-1', IDLE_SCREEN)
    await idleFor(160)

    const result = (await invoke('plan:refresh', fakeContents(), 'stuck-1')) as RefreshResult
    expect(result).toMatchObject({ ok: false, reason: 'panel-open', typed: true, residue: true })
    // Two presses and then the truth — never a third.
    expect(wrote).toEqual(['/usage\r', ESC, ESC])
    dropPlanSession('stuck-1')
  })

  it('waits out a scan rather than calling it an empty panel', async () => {
    const wrote: string[] = []
    let opened = 0
    const { invoke } = wire((id, data) => {
      wrote.push(data)
      if (data.includes('/usage')) {
        opened += 1
        paint(id, PANEL_SCANNING)
        // The limits arrive later than the first poll, and while the panel is
        // still saying `Esc to cancel`. A reader that treated "no limits yet"
        // as the answer would have given up before this landed.
        setTimeout(() => paint(id, PANEL_WITH_LIMITS), 700)
      }
      if (data === ESC) paint(id, IDLE_SCREEN)
    }, FAST)
    invoke('plan:watch', fakeContents(), 'scan-1')
    paint('scan-1', IDLE_SCREEN)
    await idleFor(160)

    const result = (await invoke('plan:refresh', fakeContents(), 'scan-1')) as RefreshResult
    expect(opened).toBe(1)
    expect(result).toMatchObject({ ok: true, reason: null, residue: false })
    expect(result.snapshot.limits.map((limit) => limit.id)).toEqual(['session', 'week'])
    dropPlanSession('scan-1')
  })

  it('brings a panel down whose scan never ends', async () => {
    const wrote: string[] = []
    const { invoke } = wire((id, data) => {
      wrote.push(data)
      if (data.includes('/usage')) paint(id, PANEL_SCANNING)
      if (data === ESC) paint(id, IDLE_SCREEN)
    }, FAST)
    invoke('plan:watch', fakeContents(), 'forever-1')
    paint('forever-1', IDLE_SCREEN)
    await idleFor(160)

    const result = (await invoke('plan:refresh', fakeContents(), 'forever-1')) as RefreshResult
    // Bounded, and closed. The scan is the CLI's business; the panel is this
    // app's, because this app opened it.
    expect(result).toMatchObject({ ok: false, reason: 'no-limits', residue: false })
    expect(wrote).toEqual(['/usage\r', ESC])
    dropPlanSession('forever-1')
  })
})

describe('an account with no plan limits is an answer, not a timeout', () => {
  const ESC = String.fromCharCode(27)
  const FAST: RefreshTimings = {
    idleBeforeTyping: 120,
    panelAppears: 900,
    settledGrace: 500,
    scanCeiling: 2_500,
    closeSettle: 700,
  }

  function paint(sessionId: string, text: string): void {
    feed(sessionId, `\u001b[2J\u001b[H${text}`)
  }

  /** A CLI whose `/usage` panel is his: complete, and with no limits in it. */
  function apiAccount(sessionId: string, wrote: string[]): { invoke: ReturnType<typeof wire>['invoke'] } {
    const { invoke } = wire((id, data) => {
      wrote.push(data)
      if (data.includes('/usage')) paint(id, PANEL_WITHOUT_LIMITS)
      if (data === ESC) paint(id, IDLE_SCREEN)
    }, FAST)
    invoke('plan:watch', fakeContents(), sessionId)
    paint(sessionId, IDLE_SCREEN)
    return { invoke }
  }

  it('reports that there are no limits, rather than that there was no panel', async () => {
    const wrote: string[] = []
    const { invoke } = apiAccount('api-1', wrote)
    await idleFor(160)

    const result = (await invoke('plan:refresh', fakeContents(), 'api-1')) as RefreshResult
    expect(result).toMatchObject({ ok: false, reason: 'no-limits', typed: true, residue: false })
    expect(wrote).toEqual(['/usage\r', ESC])
    dropPlanSession('api-1')
  })

  it('does not ask the same session again on its own', async () => {
    const wrote: string[] = []
    const { invoke } = apiAccount('api-2', wrote)
    await idleFor(160)

    await invoke('plan:refresh', fakeContents(), 'api-2')
    const typedOnce = wrote.length
    await idleFor(160)
    const again = (await invoke('plan:refresh', fakeContents(), 'api-2')) as RefreshResult

    // The whole of the "repeatedly" in his message. A question whose answer
    // cannot change is asked once.
    expect(again).toMatchObject({ ok: false, reason: 'no-limits', typed: false, residue: false })
    expect(wrote.length).toBe(typedOnce)
    dropPlanSession('api-2')
  })

  it('lets a person ask anyway', async () => {
    const wrote: string[] = []
    const { invoke } = apiAccount('api-3', wrote)
    await idleFor(160)

    await invoke('plan:refresh', fakeContents(), 'api-3')
    const typedOnce = wrote.length
    await idleFor(160)
    const pressed = (await invoke('plan:refresh', fakeContents(), 'api-3', true)) as RefreshResult

    // A press is a person, and a person may ask a second time. This is what
    // keeps the control in the panel from being a control that does nothing.
    expect(pressed.typed).toBe(true)
    expect(wrote.length).toBeGreaterThan(typedOnce)
    dropPlanSession('api-3')
  })

  it('does not hang when the session is closed mid-check', async () => {
    const wrote: string[] = []
    const { invoke } = wire((id, data) => {
      wrote.push(data)
      if (data.includes('/usage')) paint(id, PANEL_SCANNING)
    }, FAST)
    invoke('plan:watch', fakeContents(), 'gone-1')
    paint('gone-1', IDLE_SCREEN)
    await idleFor(160)

    const running = invoke('plan:refresh', fakeContents(), 'gone-1') as Promise<RefreshResult>
    // The tab is closed while the panel is up, which disposes the tracker under
    // the loop that is reading it. The awaited flush inside that loop is the
    // thing that would never resolve if a disposed terminal were asked for one.
    setTimeout(() => dropPlanSession('gone-1'), 400)
    const result = await running

    expect(result).toMatchObject({ ok: false, reason: 'not-watching', typed: true })
    // And no Escape was sent into a pty that is not there any more.
    expect(wrote).toEqual(['/usage\r'])
  })

  it('leaves a session alone once its panel has proved unclosable', async () => {
    const wrote: string[] = []
    const { invoke } = wire((id, data) => {
      wrote.push(data)
      if (data.includes('/usage')) paint(id, PANEL_WITH_LIMITS)
    }, FAST)
    invoke('plan:watch', fakeContents(), 'stuck-2')
    paint('stuck-2', IDLE_SCREEN)
    await idleFor(160)

    await invoke('plan:refresh', fakeContents(), 'stuck-2')
    const typedOnce = wrote.length
    const again = (await invoke('plan:refresh', fakeContents(), 'stuck-2')) as RefreshResult

    // An app that has just failed to clean up after itself does not get to make
    // a second mess on the same screen without being asked.
    expect(again).toMatchObject({ reason: 'panel-open', typed: false })
    expect(wrote.length).toBe(typedOnce)
    dropPlanSession('stuck-2')
  })
})
