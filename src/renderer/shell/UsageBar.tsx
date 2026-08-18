import { Fragment, useCallback, useEffect, useRef, useState } from 'react'
import type { ProviderId } from '@shared/types'
import { accountIdentity, useAccountIdentity } from '../accounts'
import { useFeatures } from '../features/FeaturesProvider'
import { ProviderBadge } from '../components/ProviderBadge'
import { providerOption } from '../components/ProviderPicker'
import { useAutoUsage } from './auto-usage'
import { useOneMenu } from './one-menu'
import {
  primaryReading,
  sourceSentence,
  usageReadout,
  type UsageReadout,
  type UsageReport,
} from './usage-bar-model'
import { extraAlert, leadIsLive, usageLines, type UsageLine } from './usage-stack'
import { useUsageBar } from './useUsageBar'
import './UsageBar.css'

/**
 * How much of the account's limits are gone, on the session's own bar.
 *
 * ## What this is answering
 *
 * Asad asked for this reading three times over two recordings. First for its
 * existence — *"where we show the account, next to it we show a bar of the
 * five-hour limit — how much limit is completed, how much is left, with the time
 * of renewal"* — then, when it had been built but drawn only inside the chat
 * composer's Options panel, *"and also bring that usage bar."* Both of those are
 * done, and the third is what this file is now shaped by:
 *
 *   > *"Maybe two bars, up and down. Upper one for five hours and down one for
 *   > weekly. For weekly it will show the 55% and no need to say week here and
 *   > no even need to show the dates. For the five-hour window it will also show
 *   > the percentage and it will show the time of reset."*
 *
 *   > *"Usage should appear on its own, not need a click."* … *"Claude Code has
 *   > it, it should automatically do it and bring it here."*
 *
 * Which is three changes, and they only make sense together:
 *
 *  1. **Two fixed lines, not one variable one.** Which window each line
 *     describes is decided by `usage-stack.ts`, and is decided in advance rather
 *     than by whichever window happened to report. The screen he was looking at
 *     when he asked read `Week 81% ▬▬ resets Aug 21 at 2pm`, because the
 *     five-hour figure was missing and the weekly one had been promoted into its
 *     place — one element saying different things about different periods from
 *     one hour to the next.
 *  2. **The weekly line loses its name and its date**, exactly as asked. What
 *     names it is sitting under the line that says `5h`, in the same columns.
 *  3. **Nobody presses anything.** The `Check now` button is gone and
 *     `auto-usage.ts` does what it did, off the session's own output going
 *     quiet. Removing the button without that would not have simplified the bar,
 *     it would have emptied it: `/usage` was the only thing in this app that
 *     made Claude Code state its limits.
 *
 * ## The three things it will not do
 *
 * This feature was nearly cancelled twice for being unreliable, so the refusals
 * matter more than the drawing. They are argued in `usage-bar-model.ts` and
 * enforced there; what this file does is respect them:
 *
 *  1. **A bar only when both halves are real** — a measured fraction *and* a
 *     renewal time. Everything else is words, or a dash.
 *  2. **"Not reported" is a distinct state**, never a zero. An empty meter and
 *     an absent one are opposite claims, so a line with no figure is drawn with
 *     no meter at all rather than with a meter at 0%.
 *  3. **Nothing comes from `~/.claude.json`.** Its `cachedUsageUtilization`
 *     block has exactly the fields a bar wants and was measured at 21.3 hours
 *     stale, describing a window that had ended 17 hours earlier. The only
 *     sources are the two in `usage-ipc.ts`: Claude Code's own screen, and the
 *     rollout Codex writes as it works.
 *
 * ## Whose it is
 *
 * The panel names the agent, the login and every window, in that order, and the
 * login is resolved through `accountIdentity` — the same function the account
 * chip a few inches away calls. That is not a nicety: the bar sits beside the
 * account precisely so the two agree, and the way to make two surfaces agree is
 * to have them ask the same function rather than to word the same answer twice.
 */

/**
 * How much of itself the reading is allowed to draw.
 *
 * Three tiers, each a measured width rather than a taste — see
 * {@link UsageBarViewProps.fit}, and `SessionControls.tsx`, which decides which
 * one applies from the room its own bar actually has.
 */
export type UsageFit = 'full' | 'dense' | 'tight'

export interface UsageBarViewProps {
  /** What the session's usage looks like right now, or null before the first answer. */
  report: UsageReport | null
  /** Which agent the session runs. Decides what can be fetched and what cannot. */
  provider?: ProviderId
  /**
   * How much of itself the reading can afford to draw, measured by the cluster.
   *
   * ## Why this is a measurement and not `folded`
   *
   * It used to take the cluster's `folded` flag and give up its renewal clause
   * whenever the *controls* beside it collapsed. That was wrong, and the real
   * app is where it showed: on a session called "Update Claude Code terminal to
   * new…" the controls folded at a **1440pt window** — because `control-room.ts`
   * protects the session name's share of the bar before it gives anything to
   * the chips — and the reading dropped `resets 4:40am` while 645 pixels of room
   * sat unused. One of the two things he asked for on the five-hour line,
   * withheld because a neighbour was short of space and this one was not.
   *
   * So it now asks about *its own* room, in three tiers, each a measured figure:
   *
   * - **`full`** — 380 pixels or more. Everything: the window name, both
   *   figures, both meters, and the renewal time. 380 is measured, not reasoned;
   *   the arithmetic and the wrong first answer are in `SessionControls.tsx`
   *   beside the line that picks the tier.
   * - **`dense`** — 120 to 379. The renewal clause goes and the meters narrow.
   *   It is a caption; the figures are not — and a clause drawn as `res…` is an
   *   ellipsis where a fact should be, which is worse than no clause at all.
   * - **`tight`** — under 120. The figures alone. At the app's own minimum
   *   window width — 720, pinned in `src/main/index.ts` — a toolbar carrying a
   *   session name, a folder, a long account address and the mode switch leaves
   *   this cluster 67 pixels, and flex handed the reading 22.9 of them: enough
   *   for the word `5h` and no number at all, which is the one thing this
   *   component must never draw. Stripped to `30%` over `19%` it measures 35,
   *   which with the controls chip's 30 and the 2-pixel gap is exactly the 67
   *   that exist — so at the narrowest this app can be made, neither control is
   *   clipped by a pixel.
   */
  fit?: UsageFit
  /** What the account chip would call this login, resolved by the same function. */
  accountLabel: string | null
  /** True when the build has no usage channel at all. */
  unwired?: boolean
  /** A fetch is in flight right now. Nobody asked for it — see `auto-usage.ts`. */
  fetching?: boolean
  /** Clock, for tests and for the harness. */
  now: number
  /**
   * The value of `data-drive-anchor` this bar should carry, or undefined.
   *
   * A tour can be asked to point at a session's usage and that is a reasonable
   * thing to point at — a stop reading "this one is nearly out of its five-hour
   * window" has somewhere to put the box. `focus-target.ts` calls the kind
   * `usage`; it used to call it `usage-strip` and point at the readout inside
   * the chat composer, which was deleted when the composer's control row went
   * *"from the chat box side completely"*. This is where that reading lives now.
   *
   * Built by {@link UsageBar} rather than here, because only it knows the
   * session, and passed rather than composed inline so that **a bar with no
   * session produces no attribute at all**. The alternative — building
   * `usage:${sessionId}` in the view — writes the literal string
   * `usage:undefined` into the DOM whenever the view is rendered on its own, in
   * the harness or in its own tests, and that is an anchor that exists, matches
   * a selector and names nothing.
   */
  anchor?: string
}

/**
 * One window's meter.
 *
 * Four pixels tall and drawn twice, one line above the other, so the pair reads
 * as a single instrument rather than as two controls. The strip at the bottom of
 * a chat pane is 72px wide with a row to itself; this shares a toolbar with a
 * session name, a folder, an account, three pickers and a mode switch, and is
 * read as "roughly how far along" with the exact figure printed beside it.
 */
function Meter({ percent, level, state }: { percent: number; level: string; state: string }) {
  return (
    <span className="ub-meter" data-level={level} data-state={state} aria-hidden="true">
      {/* Clamped, because a bar cannot draw past its own track. The number
          beside it is not clamped — a limit can be exceeded, and 104% is the
          finding rather than an error.

          Rounded to two places because these fractions arrive as decimals and
          the arithmetic shows: `0.55 * 100` is 55.00000000000001 in IEEE 754,
          which React writes into the attribute verbatim. Two places is finer
          than a 40px track can draw and finer than any screen can show, so
          nothing is lost, and what is gained is a style attribute a person can
          read in devtools. */}
      <span
        className="ub-meter-fill"
        style={{ width: `${Math.round(Math.min(100, Math.max(0, percent)) * 100) / 100}%` }}
      />
    </span>
  )
}

const CARET = 'M2.5 4.5 6 8l3.5-3.5'

/** The agent's own name — "Claude Code", "Codex CLI" — never the internal id. */
function providerLabel(provider: ProviderId | undefined): string | null {
  return provider === undefined ? null : (providerOption(provider)?.label ?? null)
}

/**
 * One line in the panel: a window, what it has used, and when it renews.
 *
 * Every window is listed here, including the ones the bar has no line for. The
 * bar shows two; a Claude account can be near a limit on `Current week (Opus)`
 * as well, and this is where that is stated in full, under the source's own
 * label rather than this app's paraphrase of it.
 */
function WindowRow({ readout }: { readout: UsageReadout }) {
  /*
   * A row that has a bar states its facts; a row that has none explains itself.
   *
   * The two are different jobs. With a bar the numbers are already on screen and
   * what is left to say is when it renews and how old it is — one line, in the
   * source's own unabridged words. Without one the interesting thing *is* the
   * absence, and `detail` is the sentence that accounts for it.
   *
   * They are not both printed. The first version did, and every row then carried
   * its reset time twice — once inside the sentence and once under it, three
   * lines apart, which is precisely the "one fact printed twice" this app's own
   * account chip was corrected for.
   */
  const facts = [readout.reset ? `Renews ${readout.reset}` : null, readout.age ? `read ${readout.age}` : null]
    .filter((part): part is string => part !== null)
    .join(' · ')

  return (
    <div className="ub-row" data-state={readout.state}>
      <div className="ub-row-head">
        {/* The source's own words for the window — "Current week (all models)",
            "30-day limit" — not this app's paraphrase of them. */}
        <span className="ub-row-name">{readout.reading.label || readout.short}</span>
        <span className="ub-row-value" data-level={readout.level}>
          {readout.value}
        </span>
      </div>
      {readout.bar ? (
        <>
          <Meter percent={readout.percent ?? 0} level={readout.level} state={readout.state} />
          {facts === '' ? null : <p className="ub-row-reset">{facts}</p>}
        </>
      ) : (
        <p className="ub-row-detail">{readout.detail}</p>
      )}
    </div>
  )
}

/**
 * What goes in a line's figure column.
 *
 * The single line may spend words — `Not reported`, `Reading…` — because it has
 * the whole element to itself and because those words *are* the reading in that
 * state. A line of a pair may not: the two figures are meant to sit on one
 * vertical rule and be compared at a glance, and `Not reported` in one of them
 * is four times the width of `55%` and pushes the other's meter across the bar.
 *
 * So a pair's missing figure is an em dash. That is not a coy way of saying zero
 * — it is the absence, marked, in the one column where a number would otherwise
 * be, drawn in the same muted italic every unread value in this app wears. The
 * sentence explaining which absence it is stays where there is room for it: the
 * hover label, and the panel one click away.
 */
function lineFigure(line: UsageLine, fallback: string): string {
  if (line.slot === 'single') return line.readout?.value ?? fallback
  if (line.readout === null || line.readout.percent === null) return '—'
  return line.readout.value
}

/**
 * The presentational half, exported for its own tests and for the harness.
 *
 * Every figure arrives already decided, so what the bar says and refuses to say
 * is testable without a bridge, a session or a DOM — which is the arrangement
 * `UsageStripView` already uses, and the reason its rules could be checked at
 * all.
 */
export function UsageBarView({
  report,
  provider,
  fit = 'full',
  accountLabel,
  unwired = false,
  fetching = false,
  now,
  anchor,
}: UsageBarViewProps) {
  const [open, setOpen] = useState(false)
  const host = useRef<HTMLDivElement>(null)
  const shut = useCallback(() => setOpen(false), [])
  // One menu at a time in this window. Without it, pressing this while the
  // model picker beside it is open leaves two panels overlapping on a bar that
  // is one row tall — the overlap `one-menu.ts` was written for.
  useOneMenu(open, shut)

  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        setOpen(false)
      }
    }
    const onDown = (event: MouseEvent): void => {
      const root = host.current
      if (root && event.target instanceof Node && !root.contains(event.target)) setOpen(false)
    }
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('mousedown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('mousedown', onDown)
    }
  }, [open])

  const lines = usageLines(report, now)
  const alert = extraAlert(report, lines, now)
  const agent = providerLabel(provider)

  /*
   * The sentence for a bar with nothing behind it.
   *
   * Three different nothings, and they are not interchangeable. A build with no
   * channel cannot ever have an answer; a report that arrived carrying a reason
   * has the main process's own sentence, which says more than anything that
   * could be composed here — "Claude Code has not printed a plan-limit line in
   * this session yet", or "was released to make room"; and a report that has not
   * arrived at all is still being asked for.
   */
  const nothing = unwired
    ? 'Usage is not wired into this build.'
    : report === null
      ? 'Asking this session what it has used…'
      : (report.reason ?? 'Nothing has been reported for this session yet.')

  /* What the single line says when it has no reading. A fetch in flight is
     worth saying out loud precisely because nobody started it: without it the
     bar would sit on "Not reported" through the two seconds it takes to run. */
  const fallback = unwired ? 'Not wired' : fetching || report === null ? 'Reading…' : 'Not reported'

  /*
   * Everything the lines cannot fit, for the hover label and for a screen reader.
   *
   * It names the agent and the login as well as the windows, because the whole
   * reason this sits next to the account chip is that the two are statements
   * about one thing, and a reading that does not say whose it is invites exactly
   * the confusion a split window already caused once. Each line contributes its
   * own full sentence — including the weekly one's renewal date, which is off
   * the bar by request and is not thereby lost.
   */
  const whose = [agent, accountLabel].filter((part): part is string => part !== null).join(' · ')
  const said = lines
    .map((line) => line.readout?.detail)
    .filter((part): part is string => part !== undefined)
  const sentence = said.length === 0 ? nothing : said.join(' ')
  const title = whose === '' ? sentence : `${whose} — ${sentence}`

  /*
   * The drive anchor sits on the bar itself, not on the chip inside it and not
   * on the sheet that hangs off it.
   *
   * A tour stop that says "this session is nearly out of its five-hour window"
   * is pointing at a *reading*, and the bar is the reading; the chip is the
   * control that opens the detail panel. They occupy the same pixels today, so
   * the choice is invisible on screen and would stop being invisible the first
   * time the bar grows a second child.
   *
   * The sheet is `position: absolute`, which matters more than it looks:
   * `getBoundingClientRect` on this element does not grow to contain an
   * absolutely-positioned descendant, so a highlight cannot swell to the panel's
   * 300×460 because somebody happened to leave the detail open.
   */
  return (
    <div className="usage-bar" ref={host} data-fit={fit} data-drive-anchor={anchor}>
      <button
        type="button"
        className="cc-chip ub-stack"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={`Usage: ${title}`}
        title={title}
        onClick={() => setOpen((was) => !was)}
      >
        {/*
          Four columns shared by both lines, so the two percentages sit on one
          vertical rule and the two meters start at the same pixel. That
          alignment is the whole reason the weekly line can go without a name:
          it is identified by the column it is in and the line it is under.

          The name column stays in the grid for the weekly line even though it
          is empty — *"no need to say week here"* — because taking it out would
          shift that line's figure left and undo the alignment the pair is for.
        */}
        <span className="ub-lines">
          {lines.map((line, index) => {
            const readout = line.readout
            const last = index === lines.length - 1
            /* The renewal time is half of what he originally asked for, so it is
               on the bar rather than only in the tooltip — and it is the first
               thing to go when the cluster folds, because the alternative is a
               chip hanging off the end of the window. The weekly line never
               carries one: *"no even need to show the dates."* */
            const tail = fit === 'full' && line.showReset && readout !== null ? readout.caveat : ''
            return (
              <Fragment key={line.slot}>
                {/*
                  Cells are dropped from the markup rather than hidden in CSS,
                  and that is not a preference. A grid with three explicit
                  columns places items in order — item 4 starts row 2 — so a row
                  that renders two cells while its neighbour renders three does
                  not "lose a column", it shifts every cell after it into the
                  wrong one. `display: none` has the same effect, since a hidden
                  item is removed from the grid entirely. Every line therefore
                  renders exactly the same number of cells as the template it is
                  drawn under, and the template changes with the state.
                */}
                {fit === 'tight' ? null : <span className="ub-cell ub-name">{line.name}</span>}
                <span
                  className={
                    readout?.percent === null || readout === null
                      ? 'ub-cell ub-figure ac-value-unknown'
                      : 'ub-cell ub-figure'
                  }
                  data-level={readout?.level ?? 'ok'}
                >
                  {lineFigure(line, fallback)}
                </span>
                {/* The meters are the first whole thing to go, and they go by
                    not being rendered rather than by being hidden: an empty
                    track column would still hold its 12 pixels open, which is
                    a third of the room this state has to work with. */}
                {fit === 'tight' ? null : (
                  <span className="ub-cell ub-track">
                    {readout?.bar ? (
                      <Meter percent={readout.percent ?? 0} level={readout.level} state={readout.state} />
                    ) : null}
                  </span>
                )}
                {/* The tail column goes with the meters when the room is
                    tight: an empty grid cell still holds its column gap open,
                    and 4 pixels is an eighth of what this state has to work
                    with. Nothing is in it — the renewal clause belongs to
                    `full` and the alert is a `full`/`dense` affordance. */}
                {fit === 'tight' ? null : (
                <span className="ub-cell ub-tail">
                  {tail === '' ? null : <span className="ub-caveat">{tail}</span>}
                  {/* A window that is on neither line and is not quiet. The
                      weekly line's tail is empty by design, which is exactly the
                      room a `Current week (Opus)` at 97% needs so it cannot hide
                      behind a comfortable pair. */}
                  {last && alert !== null ? (
                    <span className="ub-alert" data-level={alert.level}>
                      {alert.short} {alert.value}
                    </span>
                  ) : null}
                </span>
                )}
              </Fragment>
            )
          })}
        </span>
        {/*
          The caret goes when the bar is tight, and it is the last thing to go.

          Everywhere else on this bar the caret is sacred — it is the mark that
          says a control opens something, and `.sc-summary` keeps its own at
          every width for exactly that reason. Here it loses, and the
          measurement is why: with it, the tight control needs 48 pixels and the
          room allows 35, so the grid overflowed its own box and the chevron was
          drawn **on top of** `18%` — a 6.9px overlap, measured in the running
          app at a 720pt window. A chevron painted through a percentage is not
          an affordance, it is a rendering fault.

          Nothing else is given up with it. The element is still a real
          button, still announces `aria-haspopup="dialog"`, still lights up on hover
          like every chip beside it, and still carries the whole reading in its
          title; and two stacked percentages are not ambiguous about what they
          are. Removed from the markup rather than hidden in CSS so that its
          absence is one fact in one place, and so the tests can see it.
        */}
        {fit === 'tight' ? null : (
          <svg className="ac-caret" width="9" height="9" viewBox="0 0 12 12" aria-hidden="true">
            <path d={CARET} fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
        )}
      </button>

      {open ? (
        <div className="ub-sheet scroll-fade" role="dialog" aria-label="Usage windows">
          {/* Whose, before what. The agent's mark and name, then the login as
              the account chip states it — same function, so the two cannot
              disagree — and only then the numbers. */}
          <header className="ub-whose">
            {provider ? <ProviderBadge provider={provider} size={13} /> : null}
            <span className="ub-whose-agent">{agent ?? 'This session'}</span>
            {accountLabel ? <span className="ub-whose-account">{accountLabel}</span> : null}
          </header>

          {report && report.readings.length > 0 ? (
            report.readings.map((reading) => (
              <WindowRow key={reading.id} readout={usageReadout(reading, now)} />
            ))
          ) : (
            <p className="ub-empty">{nothing}</p>
          )}

          {/*
            Where the numbers come from and what keeps them current — once for
            the panel rather than once per row, because a session runs one agent
            and every reading in it therefore has one source.

            The second sentence is the replacement for the `Check now` button,
            and it is here for the reason the whole review turns on: a reader who
            can see a figure is missing will look for the thing to press, and the
            honest answer is that there is nothing to press because the app is
            already doing it. Saying so is what stops the absence reading as a
            fault. Claude's is the only one that is fetched — Codex writes its
            limits into its rollout as it works, so there is nothing to ask it
            for.
          */}
          <p className="ub-foot">
            {provider === 'claude'
              ? 'Read from Claude Code’s own /usage panel. This checks by itself whenever the session goes quiet, so there is nothing to press.'
              : sourceSentence(provider === 'codex' ? 'codex-rollout' : 'claude-usage-panel')}
          </p>
        </div>
      ) : null}
    </div>
  )
}

export interface UsageBarProps {
  /** The pty this reading is about. */
  sessionId: string
  provider?: ProviderId
  /** See {@link UsageBarViewProps.fit}. Decided by the cluster's own measurement. */
  fit?: UsageFit
  /** Injectable for tests and for the harness; defaults to `window.deck`. */
  bridge?: Parameters<typeof useUsageBar>[1]
  /** Clock, for tests. */
  now?: number
}

export function UsageBar({ sessionId, provider, fit = 'full', bridge, now }: UsageBarProps) {
  /*
   * Usage is a feature that can be uninstalled, and this is one of its surfaces.
   *
   * Asked here rather than in `SessionControls`, which merely composes this:
   * the thing that can be left behind when a feature is switched off is the
   * control itself, so the control is what asks. `features/registry.ts` names
   * `chrome.usage` under the `usage` feature, beside `chat.usage`, and
   * `features-wiring.test.ts` holds this file to being the one that checks it.
   */
  const features = useFeatures()
  const usage = useUsageBar(sessionId, bridge)
  const clock = now ?? Date.now()

  /*
   * Fetching it without being asked to, which is the half of *"usage should
   * appear on its own"* that is not about drawing.
   *
   * The hook is handed the same decision the bar draws from — `leadIsLive` over
   * the same lines — rather than making its own judgement about freshness, so a
   * figure that is good enough to show is by construction good enough to leave
   * alone. See `auto-usage.ts` for why this is an event and not a timer, and for
   * why typing into somebody's session unasked is safe here.
   */
  useAutoUsage({
    sessionId,
    provider,
    /*
     * Off when the feature is off, and this is not belt-and-braces.
     *
     * The `controlOn` check below returns null and draws nothing — but hooks
     * run before any early return, so without this the fetcher would carry on
     * typing `/usage` into people's sessions for a reading no surface in the
     * app is showing. A feature that has been switched off must stop *acting*,
     * not merely stop being drawn; a switched-off feature that still touches a
     * terminal is the worst kind of leftover.
     */
    canFetch: usage.canCheck && features.controlOn('chrome.usage'),
    fetching: usage.checking,
    fresh: leadIsLive(usageLines(usage.report, clock)),
    fetch: usage.check,
  })

  /*
   * The login, asked for exactly the way the account chip asks for it.
   *
   * `useAccountIdentity` runs the agent's own `auth status` under that account's
   * configuration directory and is answered from the same place the chip beside
   * this one is answered from — so the bar cannot say "Default" while the chip
   * forty pixels away says an email address, which is a disagreement this app
   * has already shipped once in the sidebar.
   *
   * The reading's account when there is a reading, and the *report's* otherwise.
   * They are the same login; the second exists because the state this bar is in
   * most of the time has no readings at all, and "not reported" without a name
   * on it is exactly the half-answer this was moved here to stop giving.
   */
  const account = primaryReading(usage.report)?.account ?? usage.report?.account ?? null
  const signIn = useAccountIdentity(account?.id ?? null)
  const identity =
    account === null
      ? null
      : accountIdentity({ id: account.id ?? '', name: account.name ?? '' }, signIn)

  // After the hooks, never before: a component that returns early above a hook
  // is a component whose hook order changes with a setting.
  if (!features.controlOn('chrome.usage')) return null

  /*
   * The place a tour points at when it points at a session's usage.
   *
   * Built here because here is where the session is known, and left `undefined`
   * for a bar with no session so that nothing ever writes `usage:` followed by
   * nothing into the DOM. Deliberately below the feature check: switching the
   * usage control off draws no bar, so there is no element to anchor, and the
   * overlay's honest answer is `anchor-missing` rather than a box around a gap.
   *
   * The literal is spelled here rather than imported from `anchorId` in
   * `focus-target.ts`, which is the file that reads it back. That is the same
   * arrangement every other anchor in this app uses — `Sidebar.tsx` writes
   * `session-row:${tab.id}`, `GitPanel.tsx` writes its own — and it is not
   * laziness: the two sides are meant to be able to disagree, so that
   * `anchor-contract.test.ts` can catch it when they do. A shared helper would
   * make the contract agree with itself no matter what either end did.
   */
  const anchor = sessionId === '' ? undefined : `usage:${sessionId}`

  return (
    <UsageBarView
      report={usage.report}
      provider={provider}
      fit={fit}
      accountLabel={identity?.label ?? null}
      unwired={usage.unwired}
      fetching={usage.checking}
      now={clock}
      anchor={anchor}
    />
  )
}
