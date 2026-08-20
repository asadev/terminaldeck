import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { nextPanelState, opensPlan, panelNote, planStatus, retryOffered, UsageBarView } from './UsageBar'
import {
  contextFigure,
  contextLevel,
  contextPanel,
  contextSummary,
  type ContextReading,
  type UsageReport,
  type UsageWindowReading,
} from './usage-bar-model'

/**
 * What the usage element puts on the chrome, and where it is mounted.
 *
 * ## What this file is guarding after 2026-08-19
 *
 * Asad split this element in two that day, after watching it report a plan
 * figure two hours old:
 *
 *   > *"no lets keep it in the dropdown and keep context outside"*
 *
 *   > *"And we will give an icon for it instead of title."*
 *
 * So the bar now carries a **context figure** and a **plan icon**, and the two
 * are held to opposite rules because they cost opposite amounts — measured, and
 * written down in `useUsageBar.ts`. The tests below are grouped by the four
 * things that can go wrong with that:
 *
 *  1. The context figure appearing when there is nothing to report — a zero or
 *     a dash where an agent has simply never written a token count down.
 *  2. The plan icon growing words, a figure, or a second control beside it.
 *  3. The plan figures being refreshed by anything other than the panel being
 *     opened. The timer that used to do it — `auto-usage.ts` — was deleted with
 *     this change, and a test that only asserted "no interval" would not notice
 *     it coming back under another name, so what is asserted is that the file is
 *     gone and that the open handler is the only trigger.
 *  4. The placement. Asad asked for this reading twice and both times it stayed
 *     where it already was — inside the chat composer's Options panel, which a
 *     session drawn as a terminal never opens. The last block does not render
 *     anything: it reads `SessionControls.tsx` and `App.tsx` and asserts the
 *     reading is in the cluster and the cluster is on both bars.
 *
 * `react-dom/server`, like every other render test in this folder — this project
 * has no DOM in its test setup, which fixes the element in its **closed** state.
 * That is the state a person reads at a glance and the one that has to be true
 * on its own; everything inside the panel is reached through the pure functions
 * that decide it, or pinned at the source.
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
    used: { state: 'reported', fraction: 0.18 },
    resets: { state: 'described', text: '4am (Asia/Dubai)' },
    observedAt: NOW,
    reportedAt: NOW - MINUTE,
    source: 'claude-usage-panel',
    ...over,
  }
}

/** The weekly window, at the 55% he used as his example. */
const WEEK = claude({
  id: 'claude/system:claude/weekly',
  window: 'weekly',
  label: 'Current week (all models)',
  used: { state: 'reported', fraction: 0.55 },
  resets: { state: 'described', text: 'Aug 21 at 2pm (Asia/Dubai)' },
})

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

/** The live reading this app took off its own transcript while this was written. */
function context(over: Partial<ContextReading> = {}): ContextReading {
  return {
    provider: 'claude',
    state: 'ok',
    tokens: 154_057,
    window: 1_000_000,
    percent: 15.4057,
    windowBasis: 'model',
    model: 'claude-opus-5',
    modelLabel: 'Opus 5',
    sessionId: '92b0e6db-0f92-4cbb-bae9-0aa67f9a6868',
    chosen: 'inferred',
    rivals: 0,
    reportedAt: NOW - MINUTE,
    observedAt: NOW,
    detail: '154,057 of 1,000,000 tokens — 15% of the context window.',
    ...over,
  }
}

function render(props: Partial<Parameters<typeof UsageBarView>[0]> = {}): string {
  return renderToStaticMarkup(
    <UsageBarView
      report={report([claude(), WEEK])}
      provider="claude"
      accountLabel="app.imatch.ae@gmail.com"
      context={context()}
      now={NOW}
      {...props}
    />,
  )
}

/** The text of the element, tags stripped, for "is this word on the bar" asks. */
function text(html: string): string {
  return html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim()
}

const SOURCE = readFileSync(join(__dirname, 'UsageBar.tsx'), 'utf8')

describe('the context figure, which is the whole of what is outside the dropdown', () => {
  it('draws a proportion rather than a count, and no label with it', () => {
    /*
     * *"context window should be a bar instead of numbers. It should be a
     * bar."* — so what is outside the dropdown is a length, and the count that
     * used to be there (`154.1k`, this app's own reading off its own transcript
     * on the day this was written) is in the accessible name and in the panel.
     *
     * The width is asserted rather than the element's presence: a bar that
     * draws is not the same as a bar that draws the reading, and 154,057 of a
     * million window is the one number a screenshot could not tell apart from
     * a hard-coded one.
     */
    expect(render()).toContain('class="ub-cx-strip"')
    expect(render()).toMatch(/ub-cx-strip-fill" style="width:15\.4/)
    expect(text(render())).not.toContain('154.1k')
    expect(render()).toContain('Context 154.1k of 1M (15%)')
    expect(text(render())).not.toContain('Context')
    expect(text(render())).not.toContain('tokens')
  })

  it('keeps the lines to what he can read, and the jargon to the hover', () => {
    /*
     * The second pass over this panel, and the one that took things off it.
     *
     * The first turned a run-on sentence into labelled lines, which was right
     * about the shape and wrong about the content: `Session d4601913 · inferred
     * · 1 other active here` is still this app talking to itself. *"it's not
     * understandable so don't keep something which is not understandable"*, and
     * of the model row, *"the way it is typing claude-opus star dash 5 … it's
     * too messy"*.
     *
     * So the lines are the two a person acts on — which model sets the
     * denominator, and how old the figure is when that is news — and every fact
     * that came off the screen is in the panel's `title` and its accessible
     * name. Cutting it out entirely would have been the other failure: a reading
     * this app guessed at, presented as one it was told.
     */
    const panel = contextPanel(context(), NOW)
    expect(panel?.used).toBe('154.1k')
    expect(panel?.window).toBe('1M')
    expect(panel?.share).toBe('15%')
    const facts = Object.fromEntries((panel?.facts ?? []).map((fact) => [fact.label, fact.value]))
    // The name the model menu on this same bar prints, not the transcript's id.
    expect(facts.Model).toBe('Opus 5')
    // A figure written seconds ago needs no caption, so there is no row at all.
    expect(facts.Updated).toBeUndefined()
    expect(panel?.facts).toHaveLength(1)
    // The session id, the guess and the rivals are still true and still said.
    expect(panel?.provenance).toContain('claude-opus-5')
    expect(panel?.provenance).toContain('92b0e6db-0f92-4cbb-bae9-0aa67f9a6868')
    expect(panel?.provenance).toContain('rather than being told')
    // Named rather than guessed at, and the admission is simply absent.
    expect(contextPanel(context({ chosen: 'named' }), NOW)?.provenance).not.toContain(
      'rather than being told',
    )
    // And how many other conversations in the folder were being written at the
    // same time, which is the measure of how likely the guess is to be wrong.
    expect(contextPanel(context({ rivals: 2 }), NOW)?.provenance).toContain(
      '2 other conversations were active in this folder',
    )
  })

  it('prints the age only once it is news, and never as the row he caught lying', () => {
    /*
     * `Written 7d ago`, on a session he had opened minutes earlier. The lie was
     * in the reading rather than in the row — see the walk in
     * `readContextWindow`, which now picks the transcript with the newest *turn*
     * instead of the newest file — and what is left is his own test for whether
     * a row earns its place: useful when the figure is stale, noise when it is
     * current.
     */
    const fresh = contextPanel(context({ reportedAt: NOW - 30_000 }), NOW)
    expect(fresh?.facts.find((fact) => fact.label === 'Updated')).toBeUndefined()
    const old = contextPanel(context({ reportedAt: NOW - 3 * 60 * 60_000 }), NOW)
    expect(old?.facts.find((fact) => fact.label === 'Updated')?.value).toBe('3h ago')
    // And the word `Written`, which he read as being about the transcript
    // rather than about the number above it, is gone from the panel.
    expect(old?.facts.some((fact) => fact.label === 'Written')).toBe(false)
  })

  it('divides the bar only where the split can be proved, and never by cache', () => {
    /*
     * The refusal this panel is built around. Claude Code's own `/context` draws
     * `Messages`, `System tools`, `Memory files`, `System prompt`, `Skills` and
     * `Custom agents`, and every one of those is written to disk **only** when
     * somebody runs `/context` in that session: four of the 5,381 transcripts on
     * this machine carry the record and all four were made by a probe run to
     * find out. So this app draws the one split it can prove to the token —
     * resident against the window — and no other.
     *
     * The tempting wrong answer is the cache split, which is on every assistant
     * line. It is a fact about caching, not about content: on consecutive turns
     * of one session it went 765,011/372 → 22,119/738,868 → 760,987/912 with the
     * conversation unchanged. A bar drawn from it would look exactly like
     * Claude's and mean nothing.
     */
    const panel = contextPanel(context(), NOW)
    expect(panel?.segments.map((segment) => segment.key)).toEqual(['used', 'free'])
    expect(panel?.segments.map((segment) => segment.amount)).toEqual(['154.1k', '845.9k'])
    expect(panel?.segments.map((segment) => segment.share)).toEqual(['15%', '85%'])
    // Used and free are the whole of the window, which is Claude's own
    // arithmetic: on a first `/context` in a session, `total + free == max`.
    const total = (panel?.segments ?? []).reduce((sum, segment) => sum + segment.tokens, 0)
    expect(total).toBe(1_000_000)
    for (const forbidden of ['Messages', 'System prompt', 'System tools', 'Skills', 'Cache']) {
      expect((panel?.segments ?? []).map((segment) => segment.label)).not.toContain(forbidden)
    }
  })

  it('draws no bar at all when nothing on disk names a window', () => {
    /*
     * A length with no denominator is not a proportion. `~/.claude/settings.json`
     * on this machine sets `opus[1m]` and the transcript records the model
     * *without* the tag, so a session that reached 999,876 tokens would draw as
     * 500% against a 200k table value — `context-window.ts` answers `window:
     * null` rather than guess, and the panel has to honour that with an absence.
     */
    const panel = contextPanel(context({ window: null, percent: null, windowBasis: null }), NOW)
    expect(panel?.used).toBe('154.1k')
    expect(panel?.window).toBeNull()
    expect(panel?.share).toBeNull()
    expect(panel?.segments).toEqual([])
  })

  it('says the window was seen larger than the model’s, when it was', () => {
    // The `[1m]` session. `observed` means the transcript proved a window the
    // table does not know about, which changes what the percentage means — so it
    // is still said, in the hover, in a sentence rather than in the shorthand
    // `Window: seen larger than this model’s` that was on the panel.
    const seen = contextPanel(context({ windowBasis: 'observed' }), NOW)
    expect(seen?.provenance).toContain('larger than this app’s table for that model')
    // And the ordinary answer earns no clause at all: the model's own table is
    // the unremarkable case and there is nothing to remark on.
    expect(contextPanel(context(), NOW)?.provenance).not.toContain('table for that model')
  })

  it('speaks the whole reading for anyone who cannot hover it', () => {
    /*
     * A hover is not available to everybody, so the control is *named* with
     * everything — not with the two lines the panel now prints. An accessible
     * name has no width to run out of, which is why the session id is spelled in
     * full here and is not on screen at all any more.
     */
    const said = contextSummary(context(), NOW) ?? ''
    expect(said).toContain('Context 154.1k of 1M (15%)')
    expect(said).toContain('92b0e6db-0f92-4cbb-bae9-0aa67f9a6868')
    expect(said).toContain('claude-opus-5')
    expect(said).toContain('wrote this figure just now')
    expect(contextSummary(null, NOW)).toBeNull()
  })

  it('shows nothing at all for an agent that does not write one down', () => {
    /*
     * Gemini, checked on this machine rather than assumed: nine session files
     * under `~/.gemini/tmp/*` and not one token count in any of them. Not a
     * zero — a zero claims the context is empty. Not a dash either: a dash in
     * the place a number goes is still an element claiming this app is
     * measuring something.
     */
    const gemini = context({
      provider: 'gemini',
      state: 'not-reported',
      tokens: null,
      window: null,
      percent: null,
      detail: 'Gemini does not record how full its context window is.',
    })
    expect(contextFigure(gemini)).toBeNull()
    expect(contextFigure(null)).toBeNull()
    const html = render({ context: gemini })
    expect(html).not.toContain('ub-context')
    expect(text(html)).not.toContain('0')
    expect(text(html)).not.toContain('—')
  })

  it('shows nothing for a session that has not taken a turn yet, either', () => {
    // Different reason, same answer on the bar. The difference is a sentence in
    // the tooltip: `nothing-yet` becomes a figure on its own and `not-reported`
    // never will, and only one of those is worth waiting for.
    const fresh = context({ state: 'nothing-yet', tokens: null, window: null, percent: null })
    expect(contextFigure(fresh)).toBeNull()
  })

  it('gives a token count with no percentage rather than inventing a denominator', () => {
    /*
     * The refusal `context-window.ts` is built around. `~/.claude/settings.json`
     * on this machine sets `opus[1m]`, and the transcript that CLI writes records
     * the model *without* the `[1m]` tag — so a session that reached 999,876
     * tokens would draw as 500% against a 200k table value. When nothing on disk
     * names a window, `window` and `percent` are both null and the figure keeps
     * its colour rather than borrowing a limit it does not have.
     */
    const unknown = context({ window: null, percent: null, windowBasis: null, model: null })
    expect(contextFigure(unknown)).toBe('154.1k')
    expect(contextLevel(unknown)).toBe('ok')
  })

  it('colours itself on the app’s own thresholds, and only when it has a share', () => {
    expect(contextLevel(context({ percent: 15 }))).toBe('ok')
    expect(contextLevel(context({ percent: 92 }))).toBe('critical')
    // Not `critical` merely for being large: without a window there is no share.
    expect(contextLevel(context({ percent: null }))).toBe('ok')
  })
})

describe('the plan limits, behind one icon', () => {
  it('draws an icon and no figure and no words', () => {
    /*
     * *"And we will give an icon for it instead of title."* The control is a
     * glyph; everything it could have printed is in its accessible name.
     */
    const html = render()
    expect(html).toContain('ub-plan-glyph')
    expect(text(html)).not.toContain('5h')
    expect(text(html)).not.toContain('55%')
    expect(text(html)).not.toContain('Usage')
  })

  it('has a real accessible name and a title carrying the whole reading', () => {
    const html = render()
    expect(html).toContain('aria-label="Plan limits:')
    expect(html).toContain('aria-haspopup="dialog"')
    // Whose, then what — the agent and the login before the numbers, resolved
    // through the same function the account chip beside it uses.
    expect(html).toContain('Claude Code')
    expect(html).toContain('app.imatch.ae@gmail.com')
    /*
     * Every window contributes, and it contributes facts rather than a
     * sentence. `the weekly window` was this app's own paraphrase, written to
     * be dropped into prose that no longer exists; what a screen reader gets
     * now is the same order the row prints — how much, when it renews, how old.
     */
    expect(html).toContain('55% used · renews Aug 21 at 2pm (Asia/Dubai)')
    expect(html).not.toContain('weekly window')
  })

  it('takes the colour of the worst window, so a hidden limit is not hidden', () => {
    /*
     * The job `extraAlert` used to do on the bar, and the reason it existed:
     * Claude Code prints `Current week (all models)` and `Current week (Opus)`,
     * and the second is the one that actually stops people working. With every
     * window behind one control the hazard is worse, not better.
     */
    const opus = claude({
      id: 'claude/system:claude/weekly:opus',
      window: 'weekly',
      label: 'Current week (Opus)',
      used: { state: 'reported', fraction: 0.97 },
    })
    expect(render({ report: report([claude(), WEEK, opus]) })).toContain('data-level="critical"')
    expect(render()).not.toContain('data-level="critical"')
  })

  it('tells a login with no limits from a figure that has not arrived', () => {
    /*
     * The words the figure column used to carry are an attribute now. The
     * distinction they exist for is unchanged: `Not reported` describes a number
     * that is late, and an account billed through the Claude API has no rolling
     * window at all, so nothing is late and nothing is coming.
     */
    expect(planStatus({ unwired: true, noLimits: false, blocked: null, fetching: false, reported: false })).toBe('unwired')
    expect(planStatus({ unwired: false, noLimits: true, blocked: 'API billing', fetching: false, reported: false })).toBe('no-limits')
    expect(planStatus({ unwired: false, noLimits: false, blocked: 'Signed out', fetching: false, reported: false })).toBe('stopped')
    expect(planStatus({ unwired: false, noLimits: false, blocked: null, fetching: true, reported: false })).toBe('reading')
    expect(planStatus({ unwired: false, noLimits: false, blocked: null, fetching: false, reported: true })).toBe('reported')
    expect(planStatus({ unwired: false, noLimits: false, blocked: null, fetching: false, reported: false })).toBe('nothing')
  })

  it('never says “Reading…” for a login that has settled', () => {
    /*
     * The top bar on his Windows machine read `Usage Reading…` and never
     * resolved, because the fetch was being run again and again on a session
     * where it could not succeed. A state that means "wait, this is coming" must
     * not be on screen for a state that is not coming — so a settled answer
     * outranks a fetch in flight.
     */
    expect(
      planStatus({ unwired: false, noLimits: true, blocked: 'no limits', fetching: true, reported: false }),
    ).toBe('no-limits')
    const html = render({ report: report([]), blocked: 'Signed out.', fetching: true })
    expect(html).toContain('data-status="stopped"')
  })

  it('is muted rather than hidden when there is nothing to report', () => {
    // A control that is absent and a control that has nothing to report are
    // indistinguishable, and only one of them is true. The panel says which.
    const css = readFileSync(join(__dirname, 'UsageBar.css'), 'utf8')
    expect(css).toContain(".cc-chip.ub-plan[data-status='no-limits']")
    expect(css).toContain('opacity: 0.5')
    expect(css).not.toContain('display: none')
  })
})

describe('opening the dropdown is the refresh, and nothing else is', () => {
  it('has no timer file left to run one', () => {
    /*
     * `auto-usage.ts` held the quiet-timer that kept the plan figure fresh off
     * the session's own output. It is deleted, in his words — *"if we need a
     * cron to keep it updated then we need to completely remove it"* — and the
     * absence of the file is what is asserted, because a test that only checked
     * for `setInterval` would not notice the same debounce coming back under
     * another name.
     */
    expect(() => readFileSync(join(__dirname, 'auto-usage.ts'), 'utf8')).toThrow()
    expect(SOURCE).not.toContain("from './auto-usage'")
    expect(SOURCE).not.toContain('useAutoUsage({')
  })

  it('fires the fetch on the way open, once, however it was opened', () => {
    /*
     * A close is not a request for anything, and firing on both would double the
     * cost of every look for nothing. Since the panel opens on hover as well as
     * on a press, the same rule has to survive a person hovering the icon and
     * then clicking it — one continuous act of opening, and one fetch.
     */
    const shut = { open: null, pinned: false } as const
    const hovered = nextPanelState(shut, { kind: 'hover', panel: 'plan' })
    expect(opensPlan(shut, hovered)).toBe(true)
    expect(opensPlan(hovered, nextPanelState(hovered, { kind: 'press', panel: 'plan' }))).toBe(false)
    const pinned = nextPanelState(hovered, { kind: 'press', panel: 'plan' })
    expect(opensPlan(pinned, nextPanelState(pinned, { kind: 'press', panel: 'plan' }))).toBe(false)
    // And the context panel is not a plan open, whichever way it is reached.
    expect(opensPlan(shut, nextPanelState(shut, { kind: 'hover', panel: 'context' }))).toBe(false)
  })

  it('lets a press hold open what a hover opened, instead of closing it', () => {
    /*
     * The one that bites, and the reason this is a reducer rather than a
     * `setOpen(!open)`: a mouse user hovers the icon, the panel opens, they
     * click it — and a naive toggle reads its own hover as "already open" and
     * shuts the panel on the press that was meant to keep it there.
     */
    const shut = { open: null, pinned: false } as const
    const hovered = nextPanelState(shut, { kind: 'hover', panel: 'plan' })
    expect(hovered).toEqual({ open: 'plan', pinned: false })
    const pinned = nextPanelState(hovered, { kind: 'press', panel: 'plan' })
    expect(pinned).toEqual({ open: 'plan', pinned: true })
    // A second press is the only thing that closes what a press opened…
    expect(nextPanelState(pinned, { kind: 'press', panel: 'plan' })).toEqual(shut)
    // …the pointer leaving does not, which is the whole difference between a
    // panel you hovered and a panel you asked for.
    expect(nextPanelState(pinned, { kind: 'leave' })).toEqual(pinned)
    expect(nextPanelState(hovered, { kind: 'leave' })).toEqual(shut)
    // Nor does the pointer wandering onto the other trigger swap it out.
    expect(nextPanelState(pinned, { kind: 'hover', panel: 'context' })).toEqual(pinned)
    // Escape and an outside press always win.
    expect(nextPanelState(pinned, { kind: 'shut' })).toEqual(shut)
  })

  it('reaches the same panel from a hover and from a click, not two renderings', () => {
    /*
     * *"it should show the same as we show on click hover should sho the same
     * one as hover too with bars"* — he had a text paragraph on hover and meters
     * on click, for one reading. There is one sheet in this file and one set of
     * rows in it; the trigger only decides which panel it holds.
     */
    expect(SOURCE.match(/className="ub-sheet/g) ?? []).toHaveLength(1)
    expect(SOURCE).toContain("send({ kind: 'hover', panel: 'plan' })")
    expect(SOURCE).toContain("send({ kind: 'press', panel: 'plan' })")
    // And no native tooltip on either *control*, which is what would open over
    // the panel it duplicates — the two surfaces for one reading he was
    // complaining about. The single `title` this file has is on the context
    // section *inside* the sheet, where the pointer is already at rest on the
    // thing it is asking about, and it carries the provenance the panel stopped
    // printing on his behalf.
    expect(SOURCE.match(/title=\{/g) ?? []).toHaveLength(1)
    expect(SOURCE).toContain('<section className="ub-cx" title={')
  })

  it('opens without forcing, because a look is not an override', () => {
    /*
     * `force` reaches past a login that has settled on "no subscription limits",
     * and it is reserved for the retry inside the panel, in view of the sentence
     * explaining what it overrides. The main process holds the real restraint —
     * one probe per login per minute, against the account.
     */
    expect(SOURCE).toContain('onOpen={usage.canCheck && features.controlOn(\'chrome.usage\') ? () => usage.check() : undefined}')
    expect(SOURCE).toContain('onCheck={() => usage.check(true)}')
  })

  it('does not chase a plan figure the CLI would refuse to refetch', () => {
    /*
     * Claude Code throttles its own usage fetch to once every five minutes —
     * `CLI_CACHE_WRITE_THROTTLE_MS` in `usage-probe.ts` — so two opens inside
     * five minutes cannot produce two different numbers. The panel states when
     * each figure was *read* rather than implying "now", and the main process
     * declines to start anything inside that window.
     */
    const hook = readFileSync(join(__dirname, 'useUsageBar.ts'), 'utf8')
    expect(hook).toContain('which is why every row in the panel says when it was')
    const probe = readFileSync(join(__dirname, '../../main/usage-probe.ts'), 'utf8')
    expect(probe).toContain('CLI_CACHE_WRITE_THROTTLE_MS = 300_000')
    /*
     * The twelve-minute bug, at the gate that caused it.
     *
     * The rows read `read 12m ago` on a panel whose whole premise is that
     * opening it is the fetch, and the reason was here: the disk-cache
     * short-circuit asked whether any reading was still *drawable*, and
     * `isDrawable` retires a weekly reading after fourteen hours. Every reading
     * from one CLI fetch shares a timestamp, so the weekly row kept the login
     * looking current all day and no probe was ever started. The question is now
     * the CLI's own write throttle, which is the only thing that decides whether
     * asking can produce a different answer.
     */
    const ipc = readFileSync(join(__dirname, '../../main/usage-ipc.ts'), 'utf8')
    expect(ipc).toContain('accountFigureIsAsFreshAsItCanBe')
    expect(ipc).not.toContain('accountHasLiveReading')
  })

  it('has no paragraph inside the panel at all — every state, including the empty one', () => {
    /*
     * Asad, 2026-08-20, looking at this exact cluster: *"I said to you, don't
     * put any single statement in anywhere. Everywhere you are putting a lot of
     * statements… We are not making this for the dumb people."*
     *
     * The review before this one deleted one line out of this panel and left
     * nine behind it: an empty-state paragraph, a running line, a failure line,
     * a Codex provenance line, and two states that stacked two paragraphs each.
     * The default state of a freshly opened session was one of them — so the
     * first thing this panel ever showed anybody was a paragraph.
     *
     * Every element that could hold prose is named here, so the habit cannot
     * come back under a new class name.
     */
    for (const gone of ['ub-empty', 'ub-running', 'ub-failed', 'ub-foot', 'footNote']) {
      expect(SOURCE, `${gone} puts a sentence back inside the panel`).not.toContain(gone)
    }
    expect(SOURCE).not.toContain("'Fetched by Claude Code itself")
    const hook = readFileSync(join(__dirname, 'useUsageBar.ts'), 'utf8')
    expect(hook).toContain('no session is typed into')
    expect(hook).toContain('Opening the panel is what asks, so there is nothing to press')
  })

  it('puts the one explanation that survives behind the ⓘ, and only where there is no figure', () => {
    /*
     * *"Just if somewhere it's very required, give the i icon like other ones,
     * information icon in the settings, same way."* `HoverNote` is that dot —
     * the same component every Settings pane wears — and this panel had not used
     * it once.
     *
     * The rule it is held to: a dot **only** where the panel has no number in
     * it. Beside a working reading it would be an explanation attached to
     * something that needs none, which is the habit rather than the fix.
     */
    expect(SOURCE).toContain("from '../components/HoverNote'")
    expect(SOURCE).toContain('<HoverNote label="these plan limits">{note}</HoverNote>')

    const base = { unwired: false, withheld: null, blocked: null, failed: false, detail: null }
    // Figures on screen: no dot, whatever else is true.
    expect(panelNote({ ...base, reason: 'anything', rows: 2 })).toBeNull()
    // And no dot for a provenance sentence either — Codex's source line is gone
    // rather than moved, because it used to print under correct numbers.
    expect(SOURCE).not.toContain('sourceSentence')

    // The states with nothing to show keep exactly one string between them.
    expect(panelNote({ ...base, unwired: true, reason: null, rows: 0 })).toBe(
      'Usage is not wired into this build.',
    )
    expect(panelNote({ ...base, withheld: 'On his PC.', blocked: 'x', reason: 'y', rows: 0 })).toBe(
      'On his PC.',
    )
    expect(panelNote({ ...base, blocked: 'No subscription limits.', reason: 'y', rows: 0 })).toBe(
      'No subscription limits.',
    )
    expect(panelNote({ ...base, failed: true, detail: 'It timed out.', reason: 'y', rows: 2 })).toBe(
      'It timed out.',
    )
    expect(panelNote({ ...base, reason: 'Nothing printed yet.', rows: 0 })).toBe(
      'Nothing printed yet.',
    )
    // Nothing to say, nothing to draw.
    expect(panelNote({ ...base, reason: null, rows: 0 })).toBeNull()
  })

  it('bounds the wait, so the panel can never sit on a spinner for ever', () => {
    /*
     * Longer than the main process's own kill on purpose: `refreshUsage` gives
     * up at `PROBE_TIMEOUT_MS` and answers with a sentence, so a slow probe is
     * allowed to finish and report properly. This covers only the reply that
     * never comes back at all.
     */
    const hook = readFileSync(join(__dirname, 'useUsageBar.ts'), 'utf8')
    expect(hook).toContain('REFRESH_WAIT_CAP_MS = 18_000')
    const probe = readFileSync(join(__dirname, '../../main/usage-probe.ts'), 'utf8')
    expect(probe).toContain('PROBE_TIMEOUT_MS = 15_000')
  })

  it('shows a check is running on the ring, not in words, and keeps the old figures', () => {
    /*
     * The state is real and the sentence was a duplicate of it: `planStatus`
     * returns `reading`, the icon wears it as `data-status`, and the stylesheet
     * pulses it. So the words go and the signal stays.
     *
     * What pixels cannot do is announce themselves, so the running state keeps a
     * live region clipped to nothing — in the document for a screen reader, zero
     * pixels on the panel. And a failed check still does not clear the rows: a
     * reading that was true twenty minutes ago, labelled with its age, is worth
     * more than a blank; its sentence is now the ⓘ beside them.
     */
    expect(planStatus({ unwired: false, noLimits: false, blocked: null, fetching: true, reported: true })).toBe('reading')
    const css = readFileSync(join(__dirname, 'UsageBar.css'), 'utf8')
    expect(css).toContain("[data-status='reading']")
    expect(css).toContain('ub-plan-pulse')
    expect(SOURCE).toContain('className="ub-live" role="status"')
    expect(css).toContain('clip-path: inset(50%)')
    expect(SOURCE).toContain('read ${readout.age}')
  })

  it('keeps the context figure on a rule of its own, with no scheduled callback', () => {
    /*
     * The half of the split that is not about the dropdown. A leading-edge
     * throttle rather than a debounce: nothing is ever queued, so there is
     * nothing to cancel, nothing to fire after unmount, and no timer in the
     * window at all.
     */
    const hook = readFileSync(join(__dirname, 'useUsageBar.ts'), 'utf8')
    expect(hook).toContain('export function useContextWindow')
    expect(hook).toContain('onSessionData')
    expect(hook).not.toContain('setInterval')
    // The one `setTimeout` in the file is the bound on the plan refresh above,
    // and it is the only one there may be.
    expect(hook.match(/setTimeout\(/g) ?? []).toHaveLength(1)
  })
})

describe('nobody presses anything until the app gives up', () => {
  it('has nothing to press while the app is still doing it for you', () => {
    /*
     * *"Claude Code has it, it should automatically do it and bring it here."*
     *
     * Reachable only as a function: the control lives in the sheet, the sheet is
     * only rendered while the panel is open, and this project's render tests
     * produce a static string.
     */
    expect(retryOffered(null, () => {})).toBe(false)
  })

  it('offers one press, and only once the app has stopped asking', () => {
    /*
     * The state the deletion did not consider: an attempt found nothing and by
     * design will not try again. A sentence with no way to act on it is the dead
     * end this whole review is about — worse than the button ever was.
     */
    expect(retryOffered('Claude Code’s usage panel shows no plan limits.', () => {})).toBe(true)
    // And nothing is drawn when there is nothing behind it.
    expect(retryOffered('Claude Code’s usage panel shows no plan limits.', undefined)).toBe(false)
  })

  it('keeps the bar itself down to two controls, whatever the state', () => {
    /*
     * Counted rather than searched for by name. Three `<button>`s in the whole
     * file and two of them on the bar: the context figure, which opens its own
     * breakdown, and the icon, which opens the plan panel. The third is the retry
     * *inside* that panel, spelled through `retryOffered` so it cannot be
     * loosened without the two tests above failing. A fourth cannot be added
     * anywhere, in any state, under any label, without this failing.
     *
     * It was two until 2026-08-19, when the figure stopped being a `<span>` with
     * a tooltip. That is not a control being added to the bar — it is the same
     * reading, with the paragraph behind it turned into a panel a keyboard can
     * reach and a screen reader will announce. Nothing about it is drawn as
     * pressable: `UsageBar.css` gives it no border, no fill and no hover chip.
     *
     * `ub-check` is the class the old always-present control wore, named here so
     * that a wholesale revert is caught by its own spelling.
     */
    expect(SOURCE.match(/<button/g) ?? []).toHaveLength(3)
    expect(SOURCE).not.toContain('ub-check')
    expect(SOURCE).toContain('retryOffered(blocked, onCheck)')
  })

  it('does not claim a reading was taken when there is no reading', () => {
    /*
     * Caught by looking, which is the only way it could have been. Rendered in a
     * real instance against a session whose banner said `· Claude API ·`, the
     * detail sheet printed *"This account is billed through the Claude API"* and
     * then, four lines below it, a provenance line — for a reading that does not
     * exist, under the one state whose whole point is that there is nothing to
     * read.
     *
     * That whole class of mistake is now structural rather than guarded: there
     * is one string in this panel and it is the reason there is no figure. A
     * provenance line cannot be printed under a missing reading because
     * provenance is not printed at all, and `panelNote` answers null the moment
     * a row exists, so the dot cannot appear beside a number either.
     */
    expect(panelNote({
      unwired: false, withheld: null, blocked: 'Billed through the API.',
      failed: false, detail: null, reason: 'Nothing printed yet.', rows: 0,
    })).toBe('Billed through the API.')
    expect(SOURCE).not.toContain("? sourceSentence('claude-usage-api')")
  })

  it('does not tell the reader their session is typed into, anywhere on the bar', () => {
    /*
     * The sentence under the rows used to say where the figure came from, and
     * the true answer was *"Read from Claude Code's own /usage panel"* — this
     * app having typed `/usage` into the reader's session to produce it. It is
     * not true any more, and a line that still said it would be advertising the
     * exact thing he asked three times to have removed.
     */
    const hook = readFileSync(join(__dirname, 'useUsageBar.ts'), 'utf8')
    expect(hook).toContain('no session is typed into')
    expect(SOURCE).not.toContain("sourceSentence('claude-usage-panel')")

    const model = readFileSync(join(__dirname, 'usage-bar-model.ts'), 'utf8')
    expect(model).toContain("'claude-usage-api'")
  })

  it('asks the main process to force, and only from the press', () => {
    const hook = readFileSync(join(__dirname, 'useUsageBar.ts'), 'utf8')
    expect(hook).toContain('.call(bridge, sessionId, force)')
  })
})

describe('what the bar says when nothing has been reported', () => {
  it('separates a build with no channel from a session with nothing to say', () => {
    const unwired = render({ report: null, context: null, unwired: true })
    expect(unwired).toContain('data-status="unwired"')
    expect(unwired).toContain('Usage is not wired into this build.')
  })

  it('still draws the icon, because a missing control is a different claim', () => {
    // The bar is never empty of the control, whatever the state — a reader who
    // finds nothing there learns that the feature is unreliable, which is the
    // complaint this whole element was reviewed for.
    expect(render({ report: null, context: null })).toContain('ub-plan-glyph')
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
    expect(controls).toContain("from './UsageBar'")
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
    /*
     * Two readings of one subscription, from two channels with two rules about
     * stale numbers, is two answers on one screen.
     */
    const view = readFileSync(join(__dirname, '../components/ChatView.tsx'), 'utf8')
    for (const gone of ['UsageStrip', 'UsageBar', 'PlanSection', 'planLabel']) {
      expect(view, `${gone} draws a usage reading inside the conversation again`).not.toContain(
        gone,
      )
    }
  })
})

describe('a session that is not on this computer', () => {
  /*
   * The defect: this bar was left mounted, unchanged, over remote and server
   * sessions. Both figures on it are read *here* — the plan limits are the
   * subscription of the login signed in on this laptop, and the context window
   * is a transcript file on this disk found by an id this machine's own agent
   * wrote. So over a session running on his PC it reported one true number about
   * the wrong computer and one blank, drawn identically to a local bar with
   * nothing on screen saying which of the two you were looking at.
   *
   * The fix is not "hide the bar on remote" — the standing rule is that the
   * shape must not change between local and remote, and the goal state is a
   * figure that travels. Until it can, the element is absent with a reason
   * available. `usage-reach.ts` holds the wording and the cost of the version
   * that would make it travel.
   */
  const REMOTE = 'This session is running on another of your machines'

  it('draws no context figure, whatever it was handed', () => {
    const html = render({ withheld: `${REMOTE}.`, context: context() })
    // Absent, not dashed and not zeroed — the same rule a Gemini session gets.
    // A dash in the place a number goes is still an element claiming this app is
    // measuring something.
    expect(html).not.toContain('>154.1k<')
    expect(html).not.toContain('154,057')
  })

  it('shows no window rows, so no other machine’s percentage is on screen', () => {
    const html = render({ withheld: `${REMOTE}.`, report: report([claude(), WEEK]) })
    expect(html).not.toContain('ub-meter-fill')
    expect(text(html)).not.toContain('%')
  })

  it('says why, before anybody presses anything', () => {
    // In the accessible name the control carries at every width, which is what a
    // reader gets without opening anything. A gap with the account of it one
    // press away has already been read as a broken feature.
    const html = render({ withheld: `${REMOTE}.`, report: null, context: null })
    expect(html).toContain(REMOTE)
    expect(html).toContain('data-status="withheld"')
  })

  it('outranks every other reason the figure could be missing', () => {
    /*
     * `nothing`, `no-limits` and `stopped` are all statements about *this*
     * login, and this bar has stopped claiming to be about it. Only `unwired`
     * sits above — a build with no channel has nothing to withhold.
     */
    const withheld = 'That machine’s, not this one’s.'
    const base = { unwired: false, noLimits: true, blocked: 'API billing', fetching: true, reported: true }
    expect(planStatus({ ...base, withheld })).toBe('withheld')
    expect(planStatus({ ...base, unwired: true, withheld })).toBe('unwired')
    expect(planStatus({ ...base, withheld: null })).toBe('no-limits')
  })

  it('and the hooks stop asking, rather than asking and not drawing', () => {
    /*
     * Drawing nothing while still fetching would pay the whole cost of the
     * feature for none of it: `usage:watch` would hold a live subscription to
     * this login's readings under a bar drawn over another machine's terminal,
     * and every open of the dropdown would boot a 725 MB agent CLI here to
     * produce a figure that is then thrown away.
     */
    const hook = readFileSync(join(__dirname, 'useUsageBar.ts'), 'utf8')
    expect(hook).toContain("from './usage-reach'")
    // Three refusals: the subscription, the plan fetch, and the transcript read.
    expect(hook.match(/if \(withheld !== null\) return/g)?.length).toBe(3)
    // And the flag that stops the view offering an open at all.
    expect(hook).toContain('canCheck: withheld === null')
  })
})

/**
 * The ring, and the two ways it had stopped being one.
 *
 * Asad named this mark himself — *"give it a maybe ring icon will be better,
 * just like cloud, like this ring. So it's much more better than this thing, the
 * one you gave"* — meaning the circular progress mark Claude's own product
 * wears. Rendered on 2026-08-20 it was the right *shape* and none of the rest:
 * monochrome at every level, because both colour rules named custom properties
 * that do not exist anywhere in this app, and absent altogether at the narrowest
 * width, where the context bar had been made the control in its place.
 */
describe('the ring he picked, at every width and every level', () => {
  it('is still drawn when the cluster folds, with the context bar inside it', () => {
    /*
     * The earlier answer dropped the ring and kept the figure. That made the one
     * mark he chose for this reading the only thing on the bar that disappears
     * when a pane is narrow — and the plan limits reachable only through an
     * element that says nothing about them.
     */
    const html = render({ fit: 'tight' })
    expect(html).toContain('ub-plan-glyph')
    expect(html).toContain('ub-cx-strip')
    // One control carrying both, not two elements and not one of them missing.
    expect(html).toContain('cc-chip ub-plan ub-plan-figure')
    expect(html.match(/ub-plan-glyph/g)?.length).toBe(1)
  })

  it('paints the arc and leaves the track alone, so a level is legible', () => {
    /*
     * Both circles were `currentColor` with the track at 0.32 of it, so the
     * chip's level tinted the whole ring and the arc had nothing to be read
     * against. Claude's is a coloured arc on a neutral circle.
     */
    const html = render()
    expect(html).toContain('ub-plan-track')
    expect(html).toContain('ub-plan-arc')
    // And no `stroke` on the `<svg>` for the two to inherit from.
    expect(SOURCE).not.toContain('stroke="currentColor"\n      strokeWidth="3.4"')
  })

  it('names colours this app actually defines, for every level', () => {
    /*
     * The defect, exactly: `--accent-warning` and `--accent-danger` were written
     * in this stylesheet and defined nowhere, so both resolved to the empty
     * string, both levels inherited plain body text, and warning and critical
     * drew identically — a ring that cannot say "you are near a limit", which is
     * the one job it is on the bar for.
     *
     * Asserted against `tokens.css` rather than against a list here, so the next
     * invented token fails on the day it is written instead of on the day
     * somebody screenshots it.
     */
    const css = readFileSync(join(__dirname, 'UsageBar.css'), 'utf8')
    const tokens = readFileSync(join(__dirname, '..', 'styles', 'tokens.css'), 'utf8')
    const used = new Set([...css.matchAll(/var\((--[a-z0-9-]+)/g)].map((m) => m[1]))
    /* Published by `sheet-room.ts` at run time, so it is deliberately not in the
       token file and is always written with a fallback. */
    used.delete('--sheet-room')
    const undefined_ = [...used].filter((name) => !tokens.includes(`${name}:`))
    expect(undefined_).toEqual([])
    // And the two that were wrong, pinned by name so a revert is visible. The
    // names survive in the comment above the rule; what may not come back is a
    // `var()` reaching for either.
    expect(css).not.toContain('var(--accent-warning')
    expect(css).not.toContain('var(--accent-danger')
    expect(css).toContain("ub-plan[data-level='warning'] {\n  color: var(--color-warning);")
    expect(css).toContain("ub-plan[data-level='critical'] {\n  color: var(--color-critical);")
  })
})

/**
 * *"Now, see this window is going out of the frame. This one also going out of
 * the frame."*
 *
 * Both sheets on that header row carried a clamp that could not work: `100%` in
 * a `max-height` resolves against the containing block's *height*, so the
 * formula subtracted the chip row the panel hangs off and nothing at all for the
 * chrome above it. `sheet-room.ts` measures the number CSS cannot name.
 */
describe('the panel stays inside the window', () => {
  it('clamps to the room measured under it, in both sheets on the row', () => {
    const mine = readFileSync(join(__dirname, 'UsageBar.css'), 'utf8')
    const theirs = readFileSync(join(__dirname, 'SessionControls.css'), 'utf8')
    expect(mine).toContain('max-height: min(460px, var(--sheet-room,')
    expect(theirs).toContain('max-height: min(560px, var(--sheet-room,')
    // Both still scroll, so what the clamp cuts off is reachable rather than lost.
    expect(mine).toContain('overflow-y: auto')
    expect(theirs).toContain('overflow-y: auto')
  })

  it('measures it when the panel opens, and only then', () => {
    const room = readFileSync(join(__dirname, 'sheet-room.ts'), 'utf8')
    expect(SOURCE).toContain("import { useSheetRoom } from './sheet-room'")
    // The sheet's own top, not its anchor's: the exact number, one measurement.
    expect(room).toContain('el.getBoundingClientRect().top')
    // No timer, no observer — the app's standing rule against scheduled callbacks.
    expect(room).not.toContain('setInterval')
    expect(room).not.toContain('setTimeout')
  })
})
