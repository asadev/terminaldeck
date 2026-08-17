import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { UsageBarView } from './UsageBar'
import type { UsageReport, UsageWindowReading } from './usage-bar-model'

/**
 * What the usage bar puts on the chrome, and where it is mounted.
 *
 * Two failures are being guarded, and only one of them is about markup.
 *
 * The first is the placement. Asad asked for this bar twice and both times it
 * stayed where it already was — inside the chat composer's Options panel, which
 * a session drawn as a terminal never opens. So the last block here does not
 * render anything: it reads `SessionControls.tsx` and `App.tsx` and asserts that
 * the bar is in the cluster and that the cluster is on both bars. A component
 * that renders beautifully and is mounted nowhere is exactly the state this was
 * in when the audit found it.
 *
 * The second is the wording, which is what the rest of the file is about.
 * `react-dom/server`, like every other render test in this folder — this project
 * has no DOM in its test setup, which fixes the bar in its closed state. That is
 * the state a person reads at a glance and the one that has to be true on its
 * own.
 */

const NOW = Date.parse('2026-08-17T01:00:00.000Z')
const MINUTE = 60_000

function claude(over: Partial<UsageWindowReading> = {}): UsageWindowReading {
  return {
    id: 'claude/system:claude/five-hour',
    account: {
      provider: 'claude',
      id: 'system:claude',
      name: 'Default',
      configDir: '/Users/apple/.claude',
    },
    window: 'five-hour',
    windowMinutes: null,
    label: 'Current session',
    used: { state: 'reported', fraction: 0.39 },
    resets: { state: 'described', text: '4am (Asia/Dubai)' },
    observedAt: NOW,
    reportedAt: NOW - MINUTE,
    source: 'claude-usage-panel',
    ...over,
  }
}

function report(readings: UsageWindowReading[], reason: string | null = null): UsageReport {
  return {
    sessionId: 'pty-1',
    readings,
    reason,
    // The report names the login whether or not it has anything to report, so
    // an empty one can still say who it is empty *for*.
    account: {
      provider: 'claude',
      id: 'system:claude',
      name: 'Default',
      configDir: '/Users/apple/.claude',
    },
    assembledAt: NOW,
  }
}

function render(props: Partial<Parameters<typeof UsageBarView>[0]> = {}): string {
  return renderToStaticMarkup(
    <UsageBarView
      report={report([claude()])}
      provider="claude"
      accountLabel="app.imatch.ae@gmail.com"
      now={NOW}
      {...props}
    />,
  )
}

describe('what is on the bar', () => {
  it('shows the window, a bar, the figure and the renewal time', () => {
    // All four are the ask, in his words: *"a bar of the five-hour limit — how
    // much limit is completed, how much is left, with the time of renewal."*
    const html = render()
    expect(html).toContain('5h')
    expect(html).toContain('ub-meter-fill')
    expect(html).toContain('width:39%')
    expect(html).toContain('39%')
    expect(html).toContain('<span class="ub-caveat">resets 4am</span>')
    // The timezone the CLI printed is not lost, it is one hover away — see
    // `chipReset`, and the panel, which prints the phrase whole.
    expect(html).toContain('resetting 4am (Asia/Dubai)')
  })

  it('says whose it is, where a bar cannot fit it', () => {
    // The bar sits beside the account chip precisely so the two agree, so the
    // hover label and the accessible name carry the agent and the login.
    const html = render()
    expect(html).toContain('Claude Code')
    expect(html).toContain('app.imatch.ae@gmail.com')
  })

  it('gives up the renewal clause, and nothing else, when the cluster folds', () => {
    /*
     * The controls beside this one fold into a single chip, because a control
     * that is hidden is still reachable through the panel that hid it. A reading
     * cannot be hidden that way: out of sight it is indistinguishable from a
     * reading that does not exist, which is the one confusion this component is
     * built to prevent. So it stays, and gives up its caption.
     */
    const html = render({ folded: true })
    expect(html).toContain('5h')
    expect(html).toContain('39%')
    expect(html).toContain('ub-meter-fill')
    expect(html).not.toContain('ub-caveat')
    // …and the clause is still one hover away, whole.
    expect(html).toContain('resetting 4am (Asia/Dubai)')
  })
})

describe('what is on the bar when nothing has been reported', () => {
  it('says so in the main process’s own words rather than drawing an empty bar', () => {
    const reason =
      'Claude Code has not printed a plan-limit line in this session yet — it only does so near a limit, or when /usage is run.'
    const html = render({ report: report([], reason) })
    expect(html).toContain('Not reported')
    expect(html).not.toContain('ub-meter')
    expect(html).toContain('only does so near a limit')
  })

  it('separates a build with no channel from a session with nothing to say', () => {
    expect(render({ report: null, unwired: true })).toContain('not wired into this build')
    expect(render({ report: null })).toContain('Asking this session')
  })

  it('never draws a bar from an expired window', () => {
    /*
     * The real state of Codex on this machine: 5% of a 30-day window, measured
     * on 4 June, for a window that reset on 4 July. Exact, and about a period
     * that no longer exists — the same failure as the cached block in
     * `~/.claude.json`, which is why neither is ever drawn.
     */
    const html = render({
      provider: 'codex',
      accountLabel: 'Signed in · ChatGPT',
      report: report([
        claude({
          id: 'codex/system:codex/monthly',
          account: {
            provider: 'codex',
            id: 'system:codex',
            name: 'Default (Codex CLI)',
            configDir: '/Users/apple/.codex',
          },
          window: 'monthly',
          windowMinutes: 43200,
          label: '30-day limit',
          used: { state: 'reported', fraction: 0.05 },
          resets: { state: 'at', at: 1783130065000 },
          reportedAt: 1780538073460,
          source: 'codex-rollout',
        }),
      ]),
    })
    expect(html).toContain('Not reported')
    expect(html).toContain('window has reset')
    expect(html).not.toContain('ub-meter-fill')
    expect(html).toContain('Codex CLI')
  })
})

describe('the one action, and who may have it', () => {
  it('is offered to a Claude session, because /usage is a thing Claude Code answers', () => {
    // Not rendered here — the panel is shut in a static render — so the guard is
    // that the component only ever builds it for Claude. A Codex session must
    // not be offered a button that types an unknown command at its prompt.
    const source = readFileSync(join(__dirname, 'UsageBar.tsx'), 'utf8')
    expect(source).toContain("provider === 'claude' ? (")
    expect(source).toContain('ub-check')
  })

  it('explains a refusal rather than appearing to do nothing', () => {
    const source = readFileSync(join(__dirname, 'useUsageBar.ts'), 'utf8')
    // The sentences are the main process's own, reused from the strip that used
    // to carry this control, so one refusal cannot be explained two ways.
    expect(source).toContain('refreshFailureMessage')
  })
})

describe('where this is mounted', () => {
  const controls = readFileSync(join(__dirname, 'SessionControls.tsx'), 'utf8')
  const app = readFileSync(join(__dirname, '../App.tsx'), 'utf8')

  it('is in the chrome cluster, not in the chat composer', () => {
    /*
     * The whole finding. `UsageStrip` was mounted only from `ChatView`, so the
     * reading existed and could not be reached from a terminal session at all.
     * This asserts the placement rather than the drawing, because the drawing
     * was never the part that was missing.
     */
    expect(controls).toContain("import { UsageBar } from './UsageBar'")
    expect(controls).toContain('<UsageBar sessionId={sessionId}')
  })

  it('is therefore on the window’s bar and on every guest pane’s bar', () => {
    // Two mounts of one component: the window's toolbar carries the host
    // session's, each guest pane carries its own. A split can hold two accounts,
    // and two accounts have two different five-hour windows.
    const mounts = app.match(/<SessionControls\b/g) ?? []
    expect(mounts.length).toBe(2)
  })

  it('and the chat view does not draw the same reading a second time', () => {
    // Two readings of one subscription, from two channels with two rules about
    // stale numbers, is two answers on one screen. The strip keeps what is
    // genuinely about the session — tokens, requests, context.
    const strip = readFileSync(join(__dirname, '../chat/usage/UsageStrip.tsx'), 'utf8')
    expect(strip).not.toContain('PlanSection')
    expect(strip).not.toContain('us-plan-limit')
    expect(strip).not.toContain('planLabel')
  })
})
