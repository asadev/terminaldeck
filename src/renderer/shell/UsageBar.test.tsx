import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { retryOffered, UsageBarView } from './UsageBar'
import type { UsageReport, UsageWindowReading } from './usage-bar-model'

/**
 * What the usage element puts on the chrome, and where it is mounted.
 *
 * Three failures are being guarded, and only one of them is about markup.
 *
 * The first is the placement. Asad asked for this reading twice and both times
 * it stayed where it already was — inside the chat composer's Options panel,
 * which a session drawn as a terminal never opens. So the last block here does
 * not render anything: it reads `SessionControls.tsx` and `App.tsx` and asserts
 * that the reading is in the cluster and that the cluster is on both bars. A
 * component that renders beautifully and is mounted nowhere is exactly the state
 * this was in when the audit found it.
 *
 * The second is the shape, which is what he asked for on 2026-08-17 and what
 * most of this file is about: **two lines, five-hour above weekly**, a
 * percentage on each, the renewal time on the five-hour one alone, and no
 * `Week` and no dates anywhere on the bar.
 *
 * The third is the absence of a button. *"Claude Code has it, it should
 * automatically do it and bring it here."* `Check now` is gone, and the tests
 * that prove it is gone are worth nothing on their own — so they are paired with
 * the ones proving the thing that replaced it is wired, because deleting the
 * button without that would have emptied the bar rather than simplified it.
 *
 * `react-dom/server`, like every other render test in this folder — this project
 * has no DOM in its test setup, which fixes the element in its closed state.
 * That is the state a person reads at a glance and the one that has to be true
 * on its own.
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

function render(props: Partial<Parameters<typeof UsageBarView>[0]> = {}): string {
  return renderToStaticMarkup(
    <UsageBarView
      report={report([claude(), WEEK])}
      provider="claude"
      accountLabel="app.imatch.ae@gmail.com"
      now={NOW}
      {...props}
    />,
  )
}

/** The text of the element, tags stripped, for "is this word on the bar" asks. */
function text(html: string): string {
  return html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim()
}

describe('the two bars, stacked', () => {
  it('draws a meter and a percentage for each window', () => {
    /*
     * His words: *"Maybe two bars, up and down. Upper one for five hours and
     * down one for weekly. For weekly it will show the 55% … For the five-hour
     * window it will also show the percentage and it will show the time of
     * reset."*
     */
    const html = render()
    expect(html.match(/ub-meter-fill/g) ?? []).toHaveLength(2)
    expect(html).toContain('width:18%')
    expect(html).toContain('width:55%')
    expect(text(html)).toContain('18%')
    expect(text(html)).toContain('55%')
  })

  it('puts the five-hour line first, and names only that one', () => {
    // The order is what tells them apart once the weekly line has given up its
    // name, so it is asserted on the string rather than on the model — this is
    // the file that would catch a `flex-direction` or a `.reverse()`.
    const html = render()
    expect(text(html).indexOf('18%')).toBeLessThan(text(html).indexOf('55%'))
    expect(text(html)).toContain('5h')
  })

  it('never says “Week” and never shows the weekly date', () => {
    // *"No need to say week here and no even need to show the dates."* The
    // weekly renewal time is not lost — it is in the hover label and in the
    // panel, both of which have room for the whole phrase including its
    // timezone. It is off the bar, which is a different thing.
    const html = render()
    expect(text(html)).not.toMatch(/\bWeek\b/)
    expect(html).not.toContain('resets Aug 21')
  })

  it('shows the renewal time for the five-hour window', () => {
    const html = render()
    expect(html).toContain('<span class="ub-caveat">resets 4am</span>')
    // The timezone the CLI printed is not lost, it is one hover away — see
    // `chipReset`, and the panel, which prints the phrase whole.
    expect(html).toContain('resetting 4am (Asia/Dubai)')
  })

  it('has exactly one renewal clause, on the line that is allowed one', () => {
    expect(render().match(/ub-caveat/g) ?? []).toHaveLength(1)
  })

  it('says whose it is, where the lines cannot fit it', () => {
    // The element sits beside the account chip precisely so the two agree, so
    // the hover label and the accessible name carry the agent and the login.
    const html = render()
    expect(html).toContain('Claude Code')
    expect(html).toContain('app.imatch.ae@gmail.com')
  })

  it('gives up the renewal clause, and nothing else, when the room runs short', () => {
    /*
     * The controls beside this one fold into a single chip, because a control
     * that is hidden is still reachable through the panel that hid it. A reading
     * cannot be hidden that way: out of sight it is indistinguishable from a
     * reading that does not exist, which is the one confusion this component is
     * built to prevent. So both lines stay, and give up their caption.
     *
     * `dense` is a *measured* tier and deliberately not the controls' fold —
     * see `fit`. Following the fold meant losing the renewal time at a 1440pt
     * window whenever the session had a long name, which is not short of room by
     * any reading of the word.
     */
    const html = render({ fit: 'dense' })
    expect(html.match(/ub-meter-fill/g) ?? []).toHaveLength(2)
    expect(text(html)).toContain('18%')
    expect(text(html)).toContain('55%')
    expect(html).not.toContain('ub-caveat')
    // …and the clause is still one hover away, whole.
    expect(html).toContain('resetting 4am (Asia/Dubai)')
  })
})

describe('the narrowest bar this app can be made', () => {
  /**
   * Measured, not imagined. At the app's own minimum window width — 720, pinned
   * in `src/main/index.ts` — a toolbar carrying a session name, a folder, a long
   * account address and the mode switch leaves this cluster 67 pixels, shared
   * with the folded controls chip. Flex handed the reading 22.9 of them and it
   * drew the word `5h` and no number at all.
   *
   * `tight` is the answer: the figures, and nothing else. Everything asserted
   * below is something that has to *go* for the two numbers to come out whole,
   * so each one is a thing somebody could reasonably put back.
   */
  const html = render({ fit: 'tight' })

  it('keeps both figures', () => {
    expect(text(html)).toContain('18%')
    expect(text(html)).toContain('55%')
  })

  it('drops the window name, the meters and the renewal clause', () => {
    expect(text(html)).not.toContain('5h')
    expect(html).not.toContain('ub-meter')
    expect(html).not.toContain('ub-caveat')
  })

  it('drops the caret, which everywhere else on this bar is sacred', () => {
    /*
     * With it the control needs 48px and the cap allows 35, so the grid
     * overflowed its own box and the chevron was drawn *on top of* `18%` — a
     * 6.9px overlap, measured in the running app. A caret painted through a
     * percentage is not an affordance. The element is still a button, still
     * announces `aria-haspopup`, and still carries the whole reading in its
     * title, all of which is asserted here so that dropping the mark cannot
     * quietly become dropping the control.
     */
    expect(html).not.toContain('ac-caret')
    expect(html).toContain('aria-haspopup="dialog"')
    expect(html).toContain('<button')
    expect(html).toContain('resetting 4am (Asia/Dubai)')
  })

  it('renders one cell per line per column, so the grid cannot shear', () => {
    /*
     * A grid with N explicit columns places items in order, so a line that
     * renders fewer cells than the template does not lose a column — it pushes
     * every later cell into the wrong one, and the two lines stop being aligned,
     * which is the one thing holding the unnamed weekly line together.
     *
     * One cell a line when tight (the figure), four when there is room (name,
     * figure, meter, renewal clause). `UsageBar.css` states the matching
     * template against the same `data-fit` value, and this is what stops the two
     * being changed apart.
     */
    expect((html.match(/ub-cell/g) ?? []).length).toBe(2)
    expect((render().match(/ub-cell/g) ?? []).length).toBe(8)
  })
})

describe('one window reporting and the other silent', () => {
  it('keeps the empty line rather than promoting the other window into it', () => {
    /*
     * The exact screen he was looking at when he asked for two bars: no
     * five-hour figure, 81% for the week — and a single element that read
     * `Week 81% ▬▬ resets Aug 21 at 2pm`, because the weekly reading had been
     * promoted into the only slot there was. The percentage that is present must
     * still be the weekly one, and the missing one must still be visibly the
     * five-hour one.
     */
    const html = render({
      report: report([{ ...WEEK, used: { state: 'reported', fraction: 0.81 } }]),
    })
    expect(text(html)).toContain('5h')
    expect(text(html)).toContain('81%')
    expect(html.match(/ub-meter-fill/g) ?? []).toHaveLength(1)
    // An em dash: the absence, marked, in the column a number would be in. Not
    // a zero — an empty meter and an absent one are opposite claims, so the
    // silent line has no meter at all.
    expect(text(html)).toContain('—')
  })
})

describe('what is on the bar when nothing has been reported', () => {
  it('collapses to one line and says so in the main process’s own words', () => {
    const reason =
      'Claude Code has not printed a plan-limit line in this session yet — it only does so near a limit, or when /usage is run.'
    const html = render({ report: report([], reason) })
    expect(text(html)).toContain('Not reported')
    expect(html).not.toContain('ub-meter')
    expect(html).toContain('only does so near a limit')
  })

  it('separates a build with no channel from a session with nothing to say', () => {
    expect(render({ report: null, unwired: true })).toContain('not wired into this build')
    expect(render({ report: null })).toContain('Asking this session')
  })

  it('says a fetch is happening while one is, because nobody started it', () => {
    // A reader who did not press anything and sees "Not reported" for the two
    // seconds a fetch takes has been told the wrong thing.
    expect(text(render({ report: report([]), fetching: true }))).toContain('Reading…')
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
    expect(text(html)).toContain('Not reported')
    expect(text(html)).toContain('window has reset')
    expect(html).not.toContain('ub-meter-fill')
    expect(html).toContain('Codex CLI')
  })
})

describe('a window near its limit that has no line of its own', () => {
  it('is put on the bar beside the two that do', () => {
    // `Current week (Opus)` at 97% behind a comfortable pair is the screen this
    // whole feature was nearly cancelled for producing.
    const html = render({
      report: report([
        claude(),
        WEEK,
        claude({
          id: 'claude/system:claude/weekly-opus',
          window: 'other',
          windowMinutes: 10080,
          label: 'Current week (Opus)',
          used: { state: 'reported', fraction: 0.97 },
        }),
      ]),
    })
    expect(html).toContain('ub-alert')
    expect(text(html)).toContain('97%')
  })
})

describe('nobody presses anything until the app gives up', () => {
  it('has nothing to press while the app is still doing it for you', () => {
    /*
     * *"Claude Code has it, it should automatically do it and bring it here."*
     *
     * Exhaustive over the states a reader can actually be in, because the rule
     * is not "no button" any more — it is "no button while there is still a
     * reason to wait". Reachable only as a function: the control lives in the
     * sheet, the sheet is only rendered while the panel is open, and this
     * project's render tests produce a static string.
     */
    expect(retryOffered(null, () => {})).toBe(false)
  })

  it('offers one press, and only once the app has stopped asking', () => {
    /*
     * The state the deletion did not consider, and the one his Windows recording
     * is of: an attempt typed `/usage` into the session, found nothing, and by
     * design will not try again. A sentence with no way to act on it is the dead
     * end this whole review is about — worse than the button ever was.
     */
    expect(retryOffered('Claude Code’s usage panel shows no plan limits.', () => {})).toBe(true)
    // And nothing is drawn when there is nothing behind it.
    expect(retryOffered('Claude Code’s usage panel shows no plan limits.', undefined)).toBe(false)
  })

  it('keeps the bar itself down to one control, whatever the state', () => {
    /*
     * Counted rather than searched for by name, because the name is the thing
     * most likely to change and least likely to matter. Two `<button>`s in the
     * whole file: the chip that opens the panel, and the retry inside it — and
     * the second is spelled through `retryOffered`, so it cannot be loosened
     * without the two tests above failing. A third cannot be added anywhere, in
     * any state, under any label, without this failing.
     *
     * `ub-check` is the class the old always-present control wore, named here so
     * that a wholesale revert is caught by its own spelling.
     */
    const source = readFileSync(join(__dirname, 'UsageBar.tsx'), 'utf8')
    expect(source.match(/<button/g) ?? []).toHaveLength(2)
    expect(source).not.toContain('ub-check')
    expect(source).toContain('retryOffered(blocked, onCheck)')
  })

  it('says the settled answer rather than “Reading…” for ever', () => {
    /*
     * The top bar in his recording read `Usage Reading…` and never resolved,
     * because the fetch was being run again and again on a session where it
     * could not succeed. A word that means "wait, this is coming" must not be on
     * screen for a state that is not coming.
     */
    const stopped = render({
      report: report([], 'Claude Code has not printed a plan-limit line in this session yet.'),
      blocked: 'Claude Code’s usage panel shows no plan limits for this account, so there is nothing to read.',
      fetching: true,
    })
    expect(text(stopped)).not.toContain('Reading…')
    expect(text(stopped)).toContain('Not reported')
    // And the sentence the bar hands to a hover and to a screen reader is the
    // settled one, not the tracker's "it has not printed one yet" — which is
    // true, and reads as "give it a moment" for a state that has no moment.
    expect(stopped).toContain('no plan limits for this account')
    expect(stopped).not.toContain('has not printed a plan-limit line')
  })

  it('still says “Reading…” while a fetch really is in flight', () => {
    const trying = render({ report: report([]), fetching: true })
    expect(text(trying)).toContain('Reading…')
  })

  it('fetches by itself instead, off the session’s own output', () => {
    /*
     * Paired with the test above deliberately. Removing the button on its own
     * would not have simplified this element, it would have emptied it: `/usage`
     * is the only thing in this app that makes Claude Code state its limits, and
     * the button was the only thing that ran it. So the deletion is only correct
     * while this is wired, and the two are asserted together so neither can be
     * undone alone.
     */
    const source = readFileSync(join(__dirname, 'UsageBar.tsx'), 'utf8')
    expect(source).toContain('useAutoUsage({')
    expect(source).toContain('fetch: usage.check')
    // …and it stops when the feature is switched off. Hooks run before the
    // early return that stops this being *drawn*, so without this a
    // switched-off reading would carry on typing `/usage` into people's
    // sessions for a bar nobody can see.
    expect(source).toContain("features.controlOn('chrome.usage')")
    // The freshness judgement is the drawing layer's, not a second opinion — a
    // figure good enough to show is good enough to leave alone.
    expect(source).toContain('fresh: leadIsLive(')
  })

  it('is driven by an event, not by an interval', () => {
    // The standing rule in this project, in his words: crons and timers *"make
    // the system heavier"*. The only timers in the fetcher are one-shots.
    const auto = readFileSync(join(__dirname, 'auto-usage.ts'), 'utf8')
    expect(auto).toContain('onSessionData')
    expect(auto).not.toContain('setInterval')
  })

  it('tells the reader there is nothing to press, rather than leaving a gap', () => {
    // A person who can see a figure is missing will look for the button. The
    // honest answer is that the app is already doing it — and saying so is what
    // stops the absence reading as a fault.
    const source = readFileSync(join(__dirname, 'UsageBar.tsx'), 'utf8')
    expect(source).toContain('there is nothing to press')
  })

  it('stops for good once an attempt has typed into the session for nothing', () => {
    /*
     * The half of 2026-08-18 that is about *not* doing something.
     *
     * His message was one line — *"this is what keeps happening repeatedly"* —
     * over fifteen seconds of a `/usage` panel sitting open on a live Windows
     * session. The repetition is the defect, not a symptom of it: every attempt
     * types a command into somebody's prompt and draws a panel over their work,
     * and one that came back with nothing has no business being made again on a
     * timer or on the next keystroke.
     *
     * Asserted at the seam rather than through a hook, because this project's
     * tests have no DOM to render a hook into: the fetcher takes `blocked`, the
     * bar hands it the one `useUsageBar` computes, and the fetcher's first gate
     * is that value. Undo any one of the three and this fails.
     */
    const auto = readFileSync(join(__dirname, 'auto-usage.ts'), 'utf8')
    expect(auto).toContain('blocked: string | null')
    expect(auto).toContain('if (current.blocked !== null) return')
    const source = readFileSync(join(__dirname, 'UsageBar.tsx'), 'utf8')
    expect(source).toContain('blocked: usage.blocked')

    const hook = readFileSync(join(__dirname, 'useUsageBar.ts'), 'utf8')
    // And what sets it: whether the attempt *typed*, not which sentence it
    // carried. A refusal that typed nothing — the session was working, the
    // prompt had half a line in it — costs the session nothing and is still
    // allowed to come back.
    expect(hook).toContain("if (result?.typed === true || reason === 'no-limits' || reason === 'panel-open')")
  })

  it('asks the main process to force, and only from the press', () => {
    /*
     * The stop is enforced twice over, and deliberately: this hook can be
     * remounted, and a second window never saw the first refusal. `refresh()` in
     * `src/main/plan-limit.ts` therefore keeps its own record and refuses to type
     * again — so `force` is the one thing that can reach past it, and the one
     * caller that passes it is the button.
     */
    const source = readFileSync(join(__dirname, 'UsageBar.tsx'), 'utf8')
    expect(source).toContain('onCheck={() => usage.check(true)}')
    const hook = readFileSync(join(__dirname, 'useUsageBar.ts'), 'utf8')
    expect(hook).toContain('.call(bridge, sessionId, force)')
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
     *
     * This used to prove the point by reading `chat/usage/UsageStrip.tsx` and
     * checking the plan limit was not in it. That file is gone: the composer's
     * whole control row went with *"remove them from the chat box side
     * completely, only keep the maybe add files or something"*, and the strip
     * went with it. So the rule is now proved the stronger way — by the chat
     * view mounting no usage reading at all, rather than by one particular
     * reading being absent from a component that could always grow another.
     */
    const view = readFileSync(join(__dirname, '../components/ChatView.tsx'), 'utf8')
    for (const gone of ['UsageStrip', 'UsageBar', 'PlanSection', 'planLabel']) {
      expect(view, `${gone} draws a usage reading inside the conversation again`).not.toContain(
        gone,
      )
    }
  })
})
