import { useCallback, useEffect, useRef, useState } from 'react'
import type { ProviderId } from '@shared/types'
import { accountIdentity, useAccountIdentity } from '../accounts'
import { useFeatures } from '../features/FeaturesProvider'
import { ProviderBadge } from '../components/ProviderBadge'
import { providerOption } from '../components/ProviderPicker'
import { useOneMenu } from './one-menu'
import {
  contextFigure,
  contextLevel,
  contextPanel,
  contextShare,
  contextSummary,
  primaryReading,
  sourceSentence,
  usageReadout,
  type ContextPanel,
  type ContextReading,
  type UsageReadout,
  type UsageReport,
} from './usage-bar-model'
import type { ContextLevel } from '../chat/usage/types'
import type { ControlsTarget } from './controls-target'
import { useContextWindow, useUsageBar } from './useUsageBar'
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
 * ## And then, on 2026-08-19, he split it in two
 *
 * Everything above described one reading with two windows in it, kept fresh by
 * a quiet-timer in `auto-usage.ts`. He watched that bar report a figure two
 * hours old and set an ultimatum on it — *"if we need a cron to keep it updated
 * then we need to completely remove it"* — and then, once the costs had been
 * measured for him rather than argued at him, settled it:
 *
 *   > *"no lets keep it in the dropdown and keep context outside"*
 *
 *   > *"And we will give an icon for it instead of title."*
 *
 * So this bar now draws **two different readings under two different rules**,
 * and the rule is decided by what each one costs. Measured on this machine on
 * 2026-08-19; the numbers are in `useUsageBar.ts`'s header in full, and they
 * are the whole justification for the asymmetry:
 *
 *  1. **The context window is on the bar, permanently, live.** A number and a
 *     unit, no label at rest. It is a bounded tail read of the transcript the
 *     agent is already writing — 2–17 ms, no process — so it can be current by
 *     construction and never needs a schedule. An agent that does not report one
 *     shows *nothing*: not a zero, not a dash.
 *  2. **The plan limits are inside a dropdown behind an icon.** One control, no
 *     figure, no words. Getting a fresh plan figure boots a whole Claude Code to
 *     ask one question — 725 MB peak RSS, about 3 seconds — so **opening the
 *     dropdown is the refresh** and nothing is ever on a timer. The CLI
 *     throttles its own fetch to once per five minutes, so the panel states when
 *     each figure was *read* rather than implying "now".
 *
 * `auto-usage.ts` was deleted with that change; the argument it carried about
 * events over polling moved to `useUsageBar.ts`, beside the fetch it now
 * describes.
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
 *  3. **Nothing is drawn as live on the strength of `~/.claude.json` alone.**
 *     Its `cachedUsageUtilization` block has exactly the fields a bar wants and
 *     was measured at 21.3 hours stale, describing a window that had ended 17
 *     hours earlier.
 *
 *     This clause used to read *"nothing comes from `~/.claude.json`"* flatly,
 *     and that stopped being true on 2026-08-18: `usage-probe.ts` reads the
 *     block first, precisely because it is free and instant, and only starts a
 *     process when it has gone stale. What makes that safe is the field the old
 *     clause was really about — `fetchedAtMs`, the moment the *CLI* fetched it,
 *     which becomes `reportedAt` on the reading and is what `usageReadout` ages
 *     it by. A block is a cache with a timestamp, not a source; the distinction
 *     is the whole of the fix and it is why the sentence had to be narrowed
 *     rather than deleted.
 *
 * ## Keeping it fresh, or not keeping it at all
 *
 * There is no timer anywhere in this feature any more, and there is no
 * keystroke either. `plan:refresh`, the channel that typed `/usage` into a live
 * session and left the panel over the conversation, was deleted in 0.6.0;
 * `auto-usage.ts`, which kept the figure fresh off the session's own output
 * going quiet, was deleted on 2026-08-19. What is left is two rules:
 *
 *  - The context figure re-reads a file on events that mean the number moved —
 *    the session printing, the window being looked at — with no scheduled
 *    callback of any kind. `useContextWindow` in `useUsageBar.ts` is where that
 *    is written, including why a leading-edge throttle is not a debounce.
 *  - The plan figures refresh when somebody opens the dropdown to read them,
 *    and at no other time.
 *
 * The old third option is still closed: **an old figure is never drawn as if it
 * were current.** `usageReadout` retires a reading to `aged` after a twelfth of
 * its own window and the readout carries the age, and every row in the panel
 * prints when it was read. What changed is that this is no longer a hedge
 * against a stale bar — the aged figures are *inside* the thing you opened to
 * refresh them, so the age and the refresh are on screen together.
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
 * Two tiers now, where there were three. The middle one — `dense` — existed to
 * drop the five-hour line's renewal clause while keeping its meters, and both
 * the clause and the meters are inside the dropdown since 2026-08-19. What is
 * left on the bar is a token figure and an icon, and the only question a width
 * can still decide is whether both of them fit.
 *
 * Each threshold is a measured width rather than a taste — see
 * {@link UsageBarViewProps.fit}, and `SessionControls.tsx`, which decides which
 * one applies from the room its own bar actually has.
 */
export type UsageFit = 'full' | 'tight'

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
   * So it asks about *its own* room:
   *
   * - **`full`** — the context figure and the plan icon, side by side. Measured
   *   at 64.6 pixels together on 2026-08-19.
   * - **`tight`** — the icon folded into the figure, one control at 30.4. Not an
   *   icon dropped for tidiness: at the app's own minimum window width — 720,
   *   pinned in `src/main/index.ts` — this cluster is clamped to 106 pixels, the
   *   folded controls chip beside it wants 72, and two elements here put the row
   *   27 pixels past its own edge. Of the two, the figure is the one that must
   *   survive, because a permanently-visible context reading is the whole of
   *   what Asad asked to keep outside the dropdown; the plan limits stay
   *   reachable because the figure carries the press.
   *
   * Both the threshold and this element's own widths are measured through
   * `.harness/controls.html`; `TIGHT_BELOW_PX` in `SessionControls.tsx` holds
   * the sweep beside the line that picks the tier.
   */
  fit?: UsageFit
  /** What the account chip would call this login, resolved by the same function. */
  accountLabel: string | null
  /** True when the build has no usage channel at all. */
  unwired?: boolean
  /**
   * Why neither figure is a reading of the session on screen, when it is not.
   *
   * Set for a session running on **another computer** — a paired machine or a
   * terminal on a server. Both figures on this bar are read here: the plan
   * limits are the subscription of the login signed in on this laptop, and the
   * context window is a transcript file on this disk. Over a session that is not
   * here, the first is a true number about the wrong machine and the second is a
   * lookup for an id this disk has never seen.
   *
   * So the element does not merely go quiet, it goes *absent* — no figure, no
   * meter, no dash — and this sentence is what stands in its place, in the
   * tooltip at every width and in the panel one press away. Present before
   * anybody presses anything, which is the half that matters: a reader who finds
   * a gap and has to press to discover why has already concluded the feature is
   * broken. `usage-reach.ts` holds the decision, the wording, and the list of
   * what a version that makes these figures *travel* would need.
   */
  withheld?: string | null
  /** A fetch is in flight right now, started by this panel being opened. */
  fetching?: boolean
  /**
   * Why this login has stopped having anything to say, when it has.
   *
   * The sentence from a refresh that came back with an answer that will not
   * change — no subscription limits, not signed in, no `claude` on this machine.
   * See `blocked` in `useUsageBar`. Where it is drawn, so is the one control in
   * this component: a bar that has stopped on its own must offer the reader a
   * way to look again, or it is the dead end the whole review was about.
   * Everywhere else there is deliberately nothing to press, because the app is
   * already doing it.
   */
  blocked?: string | null
  /**
   * True when the settled answer is that this login has no subscription limits.
   *
   * It changes one word and the word matters. Every other absent reading here is
   * a number that has not arrived — Claude Code prints its limits only near one
   * or when asked, so `Not reported` is exactly right and `Reading…` sometimes
   * is too. An account billed through the Claude API has no rolling window at
   * all, so there is nothing late and nothing coming, and a bar that says
   * `Not reported` about it is reporting a failure that did not happen.
   */
  noLimits?: boolean
  /** True when the last refresh produced no numbers. See `failed` in `useUsageBar`. */
  failed?: boolean
  /**
   * What the last refresh said, printed only when it failed.
   *
   * See `failed` in `useUsageBar`: after a success this sentence is a second way
   * of saying what the rows already say, and after a failure it is the only
   * thing on screen that accounts for figures that did not move.
   */
  detail?: string | null
  /**
   * Look again. Only called from the blocked state, only by a press.
   *
   * Absent in a build or a render that has nothing to call, in which case the
   * control is not drawn — this app does not offer buttons that do nothing.
   */
  onCheck?: () => void
  /**
   * How full the model's context window is, or null when there is no reading.
   *
   * Handed in rather than fetched here, like every other figure in this view, so
   * that what the bar draws and refuses to draw is testable with no bridge and
   * no DOM. Null covers two different nothings and the view treats them the
   * same way on purpose — it draws nothing at all. See {@link contextFigure}:
   * a dash in the place a number goes is still an element claiming this app is
   * measuring something.
   */
  context?: ContextReading | null
  /**
   * Somebody opened the dropdown, which is the only thing that refreshes a plan
   * figure now.
   *
   * Fired on the way open and never on the way shut. Absent in a render with
   * nothing to call, in which case the panel still opens and still shows the
   * last figures with their ages — the panel is worth opening even when nothing
   * can be fetched into it.
   */
  onOpen?: () => void
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

/**
 * Whether this bar offers anything to press.
 *
 * ## Why this is a function and not an inline `&&`
 *
 * Because it is the rule that was reversed, and a reversed rule needs somewhere
 * a test can reach. Asad deleted `Check now` in as many words — *"usage should
 * appear on its own, not need a click"* — and the test that pinned the deletion
 * counted the button elements in this file, which is a fine way to pin
 * "there is no button" and no way at all to pin "there is a button in exactly
 * one state". The sheet this control lives in is only rendered while the panel
 * is open, and this project's render tests produce a static string with no
 * chance to open anything, so the state that matters cannot be reached through
 * a render at all. Same reason `chipMode` in `agent-presence.ts` is a function.
 *
 * ## The rule
 *
 * Nothing to press while the app is still doing it for you — which is every
 * ordinary state, including a reading that is missing because Claude Code has
 * not printed one yet. One thing to press once the app has stopped: a refresh
 * came back with an answer that will not change for being asked again, and the
 * login is remembered so nothing is started for it. That is the only state in
 * which a reader is left with a fact they cannot act on, and it is the state the
 * deletion did not consider.
 *
 * `onCheck` being absent is a build or a render with nothing to call, and a
 * control with nothing behind it is not drawn — this app's rule everywhere.
 */
export function retryOffered(blocked: string | null, onCheck: (() => void) | undefined): boolean {
  return blocked !== null && typeof onCheck === 'function'
}

/**
 * What state the plan reading is in, as one word the icon can wear.
 *
 * ## Where this came from
 *
 * The bar used to print these as words in a figure column — `Not wired`,
 * `No limits`, `Not reported`, `Reading…` — and each of them was argued for at
 * length, because the distinctions are real and this feature was nearly
 * cancelled twice for blurring them. The column is gone: Asad asked for *"an
 * icon for it instead of title"*, and an icon has no room for two words.
 *
 * The distinctions are not gone with it. They are here, as an attribute, so the
 * icon can be muted for an account that has no limits and can show a refresh
 * running without a word for it, and so a test can still hold this component to
 * telling those states apart. The sentences that say which is which are in the
 * panel, one press away, and in the tooltip at every width.
 *
 * ## The states, and why `no-limits` is not `nothing`
 *
 * `Not reported` describes a figure that has not arrived — right for Claude
 * Code, which prints its limits only near one or when asked. An account billed
 * through the Claude API has no rolling window at all, so nothing is late and
 * nothing is coming, and an icon dimmed for "waiting" would be reporting a
 * failure that did not happen. `reading` is never returned once a login has
 * settled, for the reason that shipped wrong on his Windows machine: the bar
 * read `Usage Reading…` and never resolved, because the fetch was being run
 * again and again on a session where it could not succeed.
 */
export type PlanStatus =
  | 'unwired'
  | 'withheld'
  | 'no-limits'
  | 'stopped'
  | 'reading'
  | 'reported'
  | 'nothing'

export function planStatus(input: {
  unwired: boolean
  noLimits: boolean
  blocked: string | null
  fetching: boolean
  reported: boolean
  /** See {@link UsageBarViewProps.withheld}. Optional: absent is "this computer". */
  withheld?: string | null
}): PlanStatus {
  if (input.unwired) return 'unwired'
  /*
   * Above every state below it, and the order is the claim.
   *
   * `nothing` would say a figure has not arrived, `no-limits` that there is none
   * to arrive, `stopped` that this app asked and was answered — and all three
   * are statements about *this* login, made by an element drawn over a session
   * on a different computer. The only true thing to say there is that this bar
   * is not a reading of what it is drawn over, which is what this state is.
   */
  if (input.withheld != null && input.withheld !== '') return 'withheld'
  if (input.noLimits) return 'no-limits'
  if (input.blocked !== null) return 'stopped'
  if (input.fetching) return 'reading'
  return input.reported ? 'reported' : 'nothing'
}

/**
 * The sentence under the rows, in the two states that have one — and nothing in
 * the ordinary state, which is the change he asked for.
 *
 * ## What was deleted, and where it went
 *
 * This used to end with a paragraph, and Asad quoted it back verbatim with
 * *"i dont want this inside"*:
 *
 *   > *"Fetched by Claude Code itself, in this app's own process — no session is
 *   > typed into. Opening this panel is what asks, so there is nothing to press;
 *   > the CLI will not fetch its own figure more than once every five minutes,
 *   > which is why each row says when it was read."*
 *
 * Every clause of it is true and was expensive to establish, and none of it is
 * something a person reading their own usage needs on screen: each row already
 * says when it was read, which is the only part of it that changes what a reader
 * would do. The mechanism it described now lives beside the code that performs
 * it — `check` in `useUsageBar.ts`, at the call that starts the fetch — which is
 * where the next person to change the mechanism will actually look.
 *
 * ## Why the other two survive
 *
 * Because they are not provenance, they are the account of a figure that is
 * missing. A reader who can see nothing where a number should be will look for
 * something to press, and in these two states there *is* something to press,
 * immediately below — so the sentence and the control belong together. The
 * branch is on "is there a reading", not on which reason there is not:
 * screenshotted on 2026-08-18, an API-billed login printed *"This account is
 * billed through the Claude API"* and then a provenance line four lines under
 * it, about a figure that does not exist; the second form of the same mistake
 * was caught the same day on an account that was merely signed out.
 *
 * A non-Claude session keeps its source sentence. Codex's figure is read out of
 * a rollout it writes as it works, which is a genuinely different mechanism from
 * anything else on this bar, and there is one line of it.
 */
export function footNote(input: {
  provider: ProviderId | undefined
  noLimits: boolean
  blocked: string | null
}): string | null {
  if (input.provider !== 'claude') {
    return sourceSentence(input.provider === 'codex' ? 'codex-rollout' : 'claude-usage-api')
  }
  if (input.noLimits) return 'Remembered for this account, so nothing is started to ask again.'
  if (input.blocked !== null) {
    return 'Nothing was read, so there is no figure here — and nothing is started for this session again on its own.'
  }
  return null
}

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
 * How full the context window is, on the bar itself: a proportion, not a count.
 *
 * Asad, looking at `154.1k` on the strip: *"context window should be a bar
 * instead of numbers. It should be a bar."* The figure was doing two jobs — how
 * much, and how much *of the window* — and only the second is readable at a
 * glance while an agent is printing. So the strip carries the share and the
 * count moves to where somebody who wants it can read it properly: the panel
 * this control opens prints both lengths in tokens, and the accessible name
 * carries the whole reading for anyone not looking at pixels.
 *
 * The count comes back on screen in one case, which is the case where there is
 * no proportion to draw: a transcript that names tokens and no window. Drawing
 * an empty track there would be this bar claiming a measurement it does not
 * have — the same rule that keeps a Gemini session's reading absent rather than
 * dashed — and the number is still true.
 */
function ContextBar({
  share,
  level,
  figure,
}: {
  share: number | null
  level: ContextLevel
  figure: string | null
}) {
  if (share === null) return <>{figure}</>
  return (
    <span className="ub-cx-strip" data-level={level}>
      <span className="ub-cx-strip-fill" style={{ width: `${share}%` }} />
    </span>
  )
}

/**
 * The icon that opens the plan limits: a ring, part filled.
 *
 * ## Why a ring, after three other marks were argued for and drawn
 *
 * Because he picked it. A gauge, three bars, a battery and an hourglass were
 * each chosen here on some reading of what the control *means*, and each was
 * sent back; the fourth time he named the shape himself — *"give it a maybe
 * ring icon will be better, just like cloud, like this ring"* — meaning the
 * circular progress mark Claude's own product wears for the same fact. That
 * ends the argument, and the note is kept only so nobody reopens it: the mark
 * is not chosen here any more.
 *
 * ## The one real objection, and what answers it
 *
 * A ring was rejected once for a reason that was true of the ring that was
 * drawn: *"at 13 pixels a small circle and nothing else — the arc's ends are
 * two pixels apart"*. That was an arc on a hairline track at stroke 1.8 in a
 * 24-unit box, which is 0.98 device-independent pixels once the box is 13. A
 * stroke under a pixel is a grey smear, and two of them concentric are a dot.
 *
 * So this one is drawn for the size it is used at rather than for the grid:
 * stroke 3.4 of 24 is 1.84px at 13, nearly double, and the radius is dropped to
 * 8.6 so the thicker stroke still clears the box. The track is the same stroke
 * at a third of the ink, which is what makes the shape read as a *ring* — a
 * closed circle with a heavier arc on it — rather than as a lone arc that
 * disappears when the figure is small.
 *
 * ## The arc is the reading, unlike every mark before it
 *
 * The hourglass's sand was fixed, on the argument that four pixels of bulb
 * cannot carry a level. A ring has the whole circumference to spend, so it can,
 * and a progress ring whose progress is decorative would be the kind of
 * half-true this bar has spent four revisions removing. It takes the worst
 * window — the same one {@link planStatus} colours the chip by — so the mark
 * and its colour are two statements about one number.
 *
 * With no reading there is a track and no arc: an empty ring, which is honestly
 * "nothing measured" and is still unmistakably this control. `strokeLinecap`
 * is round so a fraction too small to subtend an arc still lands as a dot on
 * the ring rather than vanishing.
 */
function MeterIcon({ percent }: { percent: number | null }) {
  const radius = 8.6
  const circumference = 2 * Math.PI * radius
  // Clamped, because a window can be reported past its own limit and a dash
  // longer than the circumference draws a second lap over the first.
  const filled = percent === null ? 0 : Math.max(0, Math.min(100, percent)) / 100
  return (
    <svg
      className="ub-plan-glyph"
      width="13"
      height="13"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="3.4"
      aria-hidden="true"
    >
      {/* The track. Same stroke as the arc so the ring has one weight, at a
          third of the ink so the arc still reads against it. */}
      <circle cx="12" cy="12" r={radius} opacity="0.32" />
      {/* And the part that is gone, from twelve o'clock clockwise. The rotation
          is on the element rather than on the path, because a dash offset
          measured from three o'clock is the kind of arithmetic that survives
          exactly until somebody changes the radius. */}
      {filled > 0 ? (
        <circle
          cx="12"
          cy="12"
          r={radius}
          strokeLinecap="round"
          strokeDasharray={`${circumference * filled} ${circumference}`}
          transform="rotate(-90 12 12)"
        />
      ) : null}
    </svg>
  )
}

/**
 * Which panel is showing, and whether a press is holding it there.
 *
 * ## Why hover and click are one state and not two
 *
 * Asad found two surfaces for one reading — *"it should show the same as we
 * show on click hover should sho the same one as hover too with bars"* — and
 * the temptation is to give the hover its own little tooltip. That is how the
 * two got out of step in the first place: the click drew meters and the hover
 * drew a paragraph of the same facts, and only one of them was maintained.
 *
 * So there is one sheet, one set of markup, and two ways to ask for it. The
 * only thing a press adds is that it *stays* — which is the whole of what a
 * press means here, and what makes the panel usable by somebody who has to move
 * the pointer off the bar to read it, or who is not using a pointer at all.
 *
 * ## The four rules, and the failure each one prevents
 *
 * - **`hover` while pinned changes nothing.** Otherwise the pointer drifting
 *   from the plan icon to the context figure would swap a panel somebody had
 *   deliberately opened out from under them.
 * - **`leave` while pinned changes nothing.** A panel opened by a press must
 *   survive the pointer leaving; that is the difference between the two.
 * - **`press` on the panel that is already pinned closes it.** A control that
 *   opens on hover and does nothing on click is a control that appears broken;
 *   a second press has to undo the first.
 * - **`press` on a panel that is merely hovered pins it rather than closing
 *   it.** This is the one that bites: a mouse user hovers, the panel opens, they
 *   click it — and a naive toggle reads its own hover as "already open" and
 *   shuts the panel on the press that was meant to keep it.
 *
 * Exported because none of it is reachable through this project's render tests,
 * which produce a static string and cannot hover anything — the same reason
 * {@link retryOffered} and `chipMode` in `agent-presence.ts` are functions.
 */
export type PanelId = 'context' | 'plan'

export interface PanelState {
  open: PanelId | null
  /** True when a press is holding it open, so pointer and focus cannot close it. */
  pinned: boolean
}

export type PanelEvent =
  | { kind: 'hover'; panel: PanelId }
  | { kind: 'press'; panel: PanelId }
  | { kind: 'leave' }
  | { kind: 'shut' }

export const PANEL_SHUT: PanelState = { open: null, pinned: false }

export function nextPanelState(state: PanelState, event: PanelEvent): PanelState {
  if (event.kind === 'shut') return PANEL_SHUT
  if (event.kind === 'leave') return state.pinned ? state : PANEL_SHUT
  if (event.kind === 'hover') return state.pinned ? state : { open: event.panel, pinned: false }
  if (state.open === event.panel && state.pinned) return PANEL_SHUT
  return { open: event.panel, pinned: true }
}

/**
 * Whether this transition is somebody opening the plan panel, which is the
 * fetch.
 *
 * The refresh policy has not changed — opening the dropdown is the only thing
 * that asks for a plan figure — but there are two ways to open it now, and both
 * are an open. What must not happen is *two* fetches for one look: hovering the
 * icon and then clicking it is one continuous act of opening the panel, and the
 * transition from `plan` to `plan` is not a new one. The main process holds the
 * real restraints in any case (one probe per login per minute, and none at all
 * while Claude Code's own five-minute write throttle means the answer cannot
 * have moved), so the cost of an accidental hover is a file read.
 */
export function opensPlan(before: PanelState, after: PanelState): boolean {
  return after.open === 'plan' && before.open !== 'plan'
}

/**
 * How full the context window is, drawn rather than described.
 *
 * ## What he asked for and what is honestly available
 *
 * He put this app's hover next to Claude Code's own `/context` panel — a header
 * row, a segmented bar, then labelled rows each with a token count and a share
 * — and asked for *"this clean and visual… keep the main bar in header and rest
 * when hover"*.
 *
 * The header and the bar are here. The row list is two rows rather than eight,
 * and that is not a shortcut: `Messages`, `System tools`, `Memory files`,
 * `System prompt` and `Skills` are written down **only** when a person runs
 * `/context` in that session, and Asad never has — four of the 5,381 transcripts
 * on this machine carry the record, and all four were made by a probe run to
 * find out. The full argument, with the counts, is on {@link ContextSegment}.
 * Drawing eight named lengths from proportions this app cannot measure would be
 * the one outcome worse than the paragraph it replaces.
 *
 * So the bar has the two lengths that are provable to the token, and under it
 * the provenance the paragraph used to bury: which model, which transcript,
 * whether that transcript was guessed at, and when the agent wrote the figure.
 */
function ContextSection({ panel }: { panel: ContextPanel }) {
  return (
    /*
     * The whole section carries the provenance as its `title`, which is where
     * the unreadable lines went rather than where they were deleted.
     *
     * On the section rather than on the bar's own button on purpose: that button
     * *opens* this panel on hover, and a native tooltip on it would race the
     * panel it duplicates — the two-surfaces-for-one-reading complaint the plan
     * icon already had its `title` removed for. Inside an open panel there is no
     * such race; the pointer is already at rest on the thing it is asking about.
     */
    <section className="ub-cx" title={panel.provenance === '' ? undefined : panel.provenance}>
      {/* The compact header row, exactly as Claude Code writes it: the figure,
          the window it sits in, and the share in brackets. Same two classes the
          plan rows below use, so the two panels are visibly one app. */}
      <div className="ub-row-head">
        <span className="ub-row-name">Context window</span>
        <span className="ub-row-value" data-level={panel.level}>
          {panel.window === null ? panel.used : `${panel.used} / ${panel.window}`}
          {panel.share === null ? '' : ` (${panel.share})`}
        </span>
      </div>

      {/*
        The bar, segmented by the one split that can be proved.

        Absent entirely when nothing on disk names a window — a length with no
        denominator is not a proportion, and a full-width bar for a session
        whose window is unknown would be the loudest wrong claim on the screen.
      */}
      {panel.segments.length > 0 ? (
        <span className="ub-cx-bar" data-level={panel.level} aria-hidden="true">
          {panel.segments.map((segment) => (
            <span
              key={segment.key}
              className="ub-cx-seg"
              data-seg={segment.key}
              /* Rounded to two places for the same reason the plan meter is:
                 these arrive as decimals and IEEE 754 writes 55.00000000000001
                 into the attribute verbatim. Two places is finer than the track
                 can draw. */
              style={{ width: `${Math.round(segment.width * 100) / 100}%` }}
            />
          ))}
        </span>
      ) : null}

      {/* And the same two lengths as rows, because a bar says "roughly" and a
          person reading a context window wants the count. */}
      {panel.segments.map((segment) => (
        <div className="ub-cx-row" key={segment.key} data-seg={segment.key}>
          <span className="ub-cx-key">
            <span className="ub-cx-dot" aria-hidden="true" />
            {segment.label}
          </span>
          <span className="ub-row-value ub-cx-amount">{segment.amount}</span>
          <span className="ub-row-value ub-cx-share">{segment.share}</span>
        </div>
      ))}

      {/*
        What is left of the provenance: the model, and how old the figure is when
        that is worth saying.

        Two lines where there were five, and the three that went are in this
        section's `title` and in its accessible name rather than gone. Asad, on
        the ones that went: *"inferred, one other active here — it's not
        understandable, so don't keep something which is not understandable"*.
        The panel he wanted under the bar is the bar, the two lengths, and short
        true lines; see {@link contextPanel} for which survived and why.
      */}
      {panel.facts.length > 0 ? (
        <div className="ub-facts">
          {panel.facts.map((fact) => (
            <div className="ub-fact" key={fact.label}>
              <span className="ub-fact-key">{fact.label}</span>
              <span className="ub-fact-value">{fact.value}</span>
            </div>
          ))}
        </div>
      ) : null}

      {/*
        There were two rows and a sentence saying why there are not eight. The
        sentence is gone; the rows are unchanged.

        Asad, on this exact line: *"Now you added only used and free… I said to
        you, don't put any single statement in anywhere. Everywhere you are
        putting a lot of statements. We don't need to give the statements. We
        want simplicity. Let the smart people use it."* The habit it stands for
        is the one worth naming: this app keeps answering a design constraint by
        writing a sentence about it on screen. The constraint is real and the
        sentence was true, and neither is a reason to print it.

        ## What the sentence said, kept here because it is still the reason

        He asked for Claude Code's own `/context` list — `Messages`, `System
        tools`, `Memory files`, `System prompt`, `Skills`, `Custom agents`,
        `Free space` — and got two lengths. Those five are not on disk: see
        {@link ContextSegment}, where the path scan is written down. They can be
        fetched — `claude --print --resume <id> "/context"` answers in about
        five seconds and spends no tokens — and three measured costs decide
        against it: it **appends ~16 KB to that session's own transcript** and
        bumps its mtime, spending his real conversation to decorate a hover; the
        row set was **not stable run to run**; and on repeat runs the rows
        **stop summing to the header figure**. If it is ever offered it belongs
        on a press *inside* this panel with those costs stated — never on the
        hover that opens it, and never as a line of prose here.
      */}
    </section>
  )
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
  withheld = null,
  fetching = false,
  blocked = null,
  noLimits = false,
  onCheck,
  detail = null,
  failed = false,
  context = null,
  onOpen,
  now,
  anchor,
}: UsageBarViewProps) {
  const [panel, setPanel] = useState<PanelState>(PANEL_SHUT)
  const host = useRef<HTMLDivElement>(null)
  const shut = useCallback(() => setPanel(PANEL_SHUT), [])
  const open = panel.open

  /*
   * Every way of opening either panel, through one reducer.
   *
   * Opening the plan panel is what refreshes the plan figures, and closing it is
   * not. That policy is unchanged and it is the whole of the freshness rule Asad
   * settled on: nothing else in this app asks for a plan figure, because a fresh
   * one costs a 725 MB Claude Code boot and the only moment worth spending it on
   * is a person opening a panel to read it. What changed is that there are two
   * ways to open — he asked for the hover and the click to show the same thing —
   * so {@link opensPlan} decides from the *transition* rather than from the
   * event, and hovering and then clicking the icon spends one fetch, not two.
   *
   * Fired beside the state change rather than in an effect keyed on `open`, so
   * that a panel closed and reopened asks again, and so that a re-render which
   * merely arrives with the panel already open — the answer landing, say — does
   * not ask a second time.
   */
  const send = useCallback(
    (event: PanelEvent): void => {
      setPanel((was) => {
        const next = nextPanelState(was, event)
        if (opensPlan(was, next)) onOpen?.()
        return next
      })
    },
    [onOpen],
  )
  // One menu at a time in this window. Without it, pressing this while the
  // model picker beside it is open leaves two panels overlapping on a bar that
  // is one row tall — the overlap `one-menu.ts` was written for.
  useOneMenu(open !== null, shut)

  useEffect(() => {
    if (open === null) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        setPanel(PANEL_SHUT)
      }
    }
    const onDown = (event: MouseEvent): void => {
      const root = host.current
      if (root && event.target instanceof Node && !root.contains(event.target)) setPanel(PANEL_SHUT)
    }
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('mousedown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('mousedown', onDown)
    }
  }, [open])

  /*
   * Every window the account reports, in the source's own order.
   *
   * The bar used to pick two of these and draw them as a fixed pair; the panel
   * has always listed all of them. With the pair gone there is one list, read
   * once here and used for three things — the icon's alert level, its tooltip
   * and the rows in the sheet — rather than three walks of the same array
   * producing three chances to disagree about what a window says.
   */
  const readouts = report ? report.readings.map((reading) => usageReadout(reading, now)) : []

  /*
   * The worst window, which is what the icon has to be able to say without
   * being opened.
   *
   * This is the job `extraAlert` used to do and the reason `usage-stack.ts`
   * existed: Claude Code's own panel prints `Current week (all models)` and
   * `Current week (Opus)`, and the second is the one that actually stops people
   * working. When the bar drew a fixed pair, a per-model window at 97% could
   * hide behind two comfortable figures. Now that no window is on the bar at
   * all, the same hazard is worse rather than better — everything is behind one
   * icon — so the icon takes the colour of the worst of them, and a reader who
   * never opens it still sees that something is near a limit.
   */
  const worst = readouts.reduce<UsageReadout | null>(
    (found, readout) =>
      readout.percent !== null && (found === null || readout.percent > (found.percent ?? 0))
        ? readout
        : found,
    null,
  )
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
   *
   * The settled sentence, printed once and in one place, so that no two
   * elements in this panel say the same thing.
   *
   * Caught by looking, which is the only way it could have been: rendered in the
   * harness and screenshotted, the blocked panel printed *"Claude Code's usage
   * panel shows no plan limits for this account"* twice, four lines apart —
   * once as the reason there is nothing to show and once as the source note.
   * The same "one fact printed twice" this app's account chip was corrected for.
   */
  const stopped = blocked
  const nothing = unwired
    ? 'Usage is not wired into this build.'
    : /*
       * A session that is not on this computer outranks every reason below,
       * because every reason below is a fact about this computer's login and
       * this bar has stopped claiming to be about it. See
       * {@link UsageBarViewProps.withheld}.
       */
      withheld !== null
      ? withheld
      : /*
       * A settled answer outranks everything below it, and that ordering is the
       * fix rather than a detail.
       *
       * `report.reason` is the tracker's sentence — *"Claude Code has not
       * printed a plan-limit line in this session yet"* — which is true, is what
       * used to be shown, and is the wrong thing to say once this app has
       * actually asked and been answered. It reads as "give it a moment", and on
       * an account with no subscription limits there is no moment that will ever
       * arrive.
       */
      stopped !== null
      ? stopped
      : report === null
        ? 'Asking this session what it has used…'
        : (report.reason ?? 'Nothing has been reported for this session yet.')

  /*
   * Everything the icon cannot say, for its hover label and for a screen reader.
   *
   * It names the agent and the login as well as every window, because the whole
   * reason this sits next to the account chip is that the two are statements
   * about one thing, and a reading that does not say whose it is invites exactly
   * the confusion a split window already caused once. Every window contributes
   * its own full sentence — including the weekly one's renewal date, which was
   * kept off the bar by request and is not thereby lost.
   *
   * This carried more weight from 2026-08-19 than it ever did, and the note is
   * worth leaving: the control it labels has no figure and no words on it at
   * all, so a person who does not open it has only this. The words the figure
   * column used to hold — `No limits`, `Not reported`, `Reading…` — are not
   * lost with it; they are {@link planStatus}, which the icon wears as an
   * attribute and which the panel says in full sentences.
   */
  const whose = [agent, accountLabel].filter((part): part is string => part !== null).join(' · ')
  const sentence = readouts.length === 0 ? nothing : readouts.map((readout) => readout.detail).join(' ')
  const title = whose === '' ? sentence : `${whose} — ${sentence}`
  const status = planStatus({ unwired, noLimits, blocked, fetching, reported: readouts.length > 0, withheld })
  /*
   * No provenance line while withholding, and it is the same rule the footnote
   * already keeps: it is *"not provenance, it is the account of a figure that is
   * missing"*, and the account of this one is `nothing` above, printed once. A
   * source sentence here would describe the mechanism by which this app reads a
   * figure it has just said it is not reading.
   */
  const foot = withheld !== null ? null : footNote({ provider, noLimits, blocked })

  /*
   * The context figure, which is the whole of what is outside the dropdown.
   *
   * Three values and no branching in the markup below: the number to print, the
   * sentence behind it and the colour it takes. All three are null-safe and all
   * three come from `usage-bar-model.ts`, so a bar with no reading draws no
   * element rather than an element with nothing in it.
   */
  const tight = fit === 'tight'
  /*
   * A withheld bar has no context reading either, whatever it was handed.
   *
   * The hook already declines to take one — `useContextWindow` never asks for a
   * session that is not on this computer — so in the running app this is not
   * reached. It is here because the two halves of that promise are enforced in
   * two different files, and this is the one that draws: a view that would
   * happily print a token count beside a sentence saying it is not reading one
   * is a view whose honesty depends on its caller remembering. Nulling it here
   * makes the absence a property of the component instead.
   */
  const reading = withheld === null ? context : null
  const figure = contextFigure(reading, tight)
  const figureName = contextSummary(reading, now)
  const figureLevel = contextLevel(reading)
  const figureShare = contextShare(reading)
  /*
   * The breakdown behind the figure, built once here and drawn in two places:
   * on its own when the figure is its own element, and above the plan rows when
   * the two have been folded into one control. Null whenever there is no
   * reading, in which case nothing below draws a section for it.
   */
  const breakdown = contextPanel(reading, now)

  /*
   * At the narrowest width the figure *is* the control.
   *
   * Measured through `.harness/controls.html` on 2026-08-19: at the app's own
   * 720px minimum window the cluster is clamped to 106 pixels, the folded
   * controls chip beside this wants 72 of them, and two elements here — a 39.6
   * figure and a 21 icon with the gap between them — put the row 27 pixels past
   * its own edge. One element fits.
   *
   * Which one goes is not a toss-up. A permanently visible context reading is
   * the whole of what Asad asked to keep outside the dropdown, and an icon is
   * the only part of this that can be folded into something else without being
   * lost: the figure takes the press, so the plan limits stay one click away at
   * every width the app can be made. Both accessible names say so.
   */
  const figureIsControl = tight && figure !== null

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
    <div
      className="usage-bar"
      ref={host}
      data-fit={fit}
      /* Which panel is showing, for the stylesheet's hover bridge — see
         `.usage-bar[data-open]::after`, the few pixels between this bar and the
         sheet under it that a pointer has to cross without leaving the bar. */
      data-open={open ?? undefined}
      data-drive-anchor={anchor}
      /*
       * The pointer leaving is asked of the whole bar, not of the trigger.
       *
       * The sheet is a child of this element, so a pointer travelling from the
       * icon down into the panel never leaves this subtree and `pointerleave`
       * does not fire — which is exactly the *"must not vanish while the pointer
       * travels to it"* case, solved by where the element sits rather than by a
       * timer that would have to be cancelled on unmount. The one gap in that
       * path is the few pixels between the bar and the top of the sheet, and
       * `.ub-sheet::before` in the stylesheet covers them.
       */
      onPointerLeave={() => send({ kind: 'leave' })}
      /*
       * And the keyboard's equivalent, which is not the same event.
       *
       * React's `onBlur` is `focusout`, so it fires here when focus moves
       * anywhere out of this subtree — tabbing off the bar closes a panel that
       * was opened by tabbing onto it. It deliberately does nothing when
       * `relatedTarget` is null: that is what a click on a non-focusable part of
       * the panel produces, and closing there would shut the sheet under the
       * pointer. An outside press is handled by the `mousedown` listener above,
       * which knows the difference.
       */
      onBlur={(event) => {
        const root = host.current
        const to = event.relatedTarget
        if (root && to instanceof Node && !root.contains(to)) send({ kind: 'leave' })
      }}
    >
      {/*
        The context figure, outside the dropdown, permanently — *"keep context
        outside"*.

        A reading first, and drawn as one: a number and a unit and no label at
        rest, because the bar it sits on is already carrying a session name, a
        folder, an account and three pickers, and because the word "context" is
        the one part of it a reader can infer. It is current by construction —
        the agent writes the figure as it works and this only looks.

        It does take a press, since 2026-08-19, and that is the one thing about
        it that changed. The detail behind it — the split against the window,
        which session, whether that session was inferred, when the agent wrote
        it — used to be a paragraph in a `title` and is now the panel below,
        opened by hovering it and held open by pressing it. Nothing about it is
        drawn as pressable; see `UsageBar.css`, which gives it no border, no fill
        and no hover chip.

        Absent entirely, rather than dashed or zeroed, when there is no reading.
        `contextFigure` returns null for a Gemini session (verified on this
        machine: nine session files under `~/.gemini/tmp/*` and no token count
        in any of them), for a plain shell, and for a Claude session that has
        not taken a turn yet. A dash in the place a number goes is still an
        element claiming this app is measuring something.
      */}
      {figure === null || figureIsControl ? null : (
        <button
          type="button"
          /*
           * `cc-reading` is what `naturalWidth` in `control-room.ts` counts.
           * Without it the cluster measures itself as this element's icon alone
           * and unfolds into a bar it overflows — the one direction that
           * measurement is not allowed to be wrong in.
           */
          className="cc-reading ub-context"
          data-level={figureLevel}
          /*
           * A real button element, where this was a bare span until the
           * breakdown existed.
           *
           * The rule it used to be written under still stands — an affordance
           * with nothing behind it is not drawn — and what changed is that there
           * *is* something behind it now: hovering opens the breakdown, and
           * pressing holds it open for somebody who has to move the pointer to
           * read it. Left as plain text it would be a panel no keyboard could
           * reach and no screen reader would announce. It keeps the reading's
           * appearance rather than a chip's, because it is still data first: no
           * border, no fill, the same tabular figure as before.
           */
          aria-haspopup="dialog"
          aria-expanded={open === 'context'}
          aria-label={figureName ?? undefined}
          onPointerEnter={() => send({ kind: 'hover', panel: 'context' })}
          onFocus={() => send({ kind: 'hover', panel: 'context' })}
          onClick={() => send({ kind: 'press', panel: 'context' })}
        >
          <ContextBar share={figureShare} level={figureLevel} figure={figure} />
        </button>
      )}

      {/*
        And the plan limits, behind one icon — *"we will give an icon for it
        instead of title"*.

        One control, no figure, no words. Everything it could have printed is in
        its accessible name and its title, and the panel it opens prints all of
        it in full. `data-status` is what the figure column's words became — see
        {@link planStatus} — so a reader can still tell a login with no limits
        from a figure that has not arrived, and so the icon can show a refresh
        running without a word for it.

        Opening it *is* the refresh, whichever way it is opened. There is no
        timer behind these numbers and nothing to press inside: the transition
        into the open state fires the fetch, and the panel draws immediately from
        what is already cached with its age stated rather than waiting for the
        answer. See `useUsageBar.ts` for what a fresh plan figure costs and why
        that is the only affordable trigger.

        Hover and click reach the same panel, in his words — *"it should show
        the same as we show on click hover should sho the same one as hover too
        with bars"*. There is no `title` on this control any more: a native
        tooltip would open over the panel it duplicates, which is the two
        surfaces for one reading he was complaining about. The whole reading is
        still spoken, in `aria-label`.
      */}
      <button
        type="button"
        className={figureIsControl ? 'cc-chip ub-plan ub-plan-figure' : 'cc-chip ub-plan'}
        aria-haspopup="dialog"
        aria-expanded={open === 'plan'}
        /* Both readings when the figure is inside it, so a screen reader is not
           told this control is about plan limits while it is drawing a context
           token count. */
        aria-label={
          figureIsControl && figureName !== null
            ? `${figureName} Plan limits: ${title}`
            : `Plan limits: ${title}`
        }
        data-status={status}
        data-level={worst?.level ?? 'ok'}
        onPointerEnter={() => send({ kind: 'hover', panel: 'plan' })}
        onFocus={() => send({ kind: 'hover', panel: 'plan' })}
        onClick={() => send({ kind: 'press', panel: 'plan' })}
      >
        {figureIsControl ? (
          <span className="ub-context" data-level={figureLevel}>
            <ContextBar share={figureShare} level={figureLevel} figure={figure} />
          </span>
        ) : (
          /* The worst window's own fraction, which is what the chip's colour
             already says in another vocabulary. */
          <MeterIcon percent={worst?.percent ?? null} />
        )}
      </button>

      {open === null ? null : (
        <div
          className="ub-sheet scroll-fade"
          role="dialog"
          aria-label={open === 'context' ? 'Context window' : 'Usage windows'}
        >
          {/*
            The context breakdown, above the plan rows or on its own.

            On its own when the figure has its own element on the bar and its own
            hover. Above the plan rows at the narrowest width, where the two have
            been folded into one control — that control is both readings, so its
            panel is both readings, which is the same argument its accessible
            name already makes.
          */}
          {breakdown !== null && (open === 'context' || figureIsControl) ? (
            <ContextSection panel={breakdown} />
          ) : null}
          {open !== 'plan' ? null : (
            <>
            {/* Whose, before what. The agent's mark and name, then the login as
                the account chip states it — same function, so the two cannot
                disagree — and only then the numbers. */}
            <header className="ub-whose">
              {provider ? <ProviderBadge provider={provider} size={13} /> : null}
              <span className="ub-whose-agent">{agent ?? 'This session'}</span>
              {accountLabel ? <span className="ub-whose-account">{accountLabel}</span> : null}
            </header>

            {/*
              The figures that are already known, drawn the instant the panel
              opens and never held back for the refresh that opened with them.
              Every row carries when it was read — `read 2h ago` — because the CLI
              throttles its own usage fetch to once every five minutes, so two
              opens inside five minutes cannot produce two different numbers and a
              panel that implied "now" would be wrong four times out of five.
            */}
            {readouts.length > 0 ? (
              readouts.map((readout) => <WindowRow key={readout.reading.id} readout={readout} />)
            ) : (
              <p className="ub-empty">{nothing}</p>
            )}

            {/*
              A refresh is running, said out loud because nobody pressed a button
              to start it — opening this panel did. Without it the panel would sit
              on figures marked `read 2h ago` for the three seconds the check
              takes, with nothing on screen saying anything was happening, and the
              reader would close it believing that is all there is.

              Bounded: `useUsageBar` gives up after eighteen seconds and says so,
              so this cannot become a spinner that never stops. That bound is
              longer than the main process's own fifteen-second kill on purpose, so
              a slow probe finishes and reports properly rather than being
              disowned a second before it answers.
            */}
            {fetching ? (
              <p className="ub-running" role="status">
                Checking with Claude Code…
              </p>
            ) : failed && detail !== null ? (
              /*
               * And what went wrong, in one plain sentence, with the old figures
               * still above it wearing their ages. The alternative — clearing the
               * rows on a failed check — throws away a true reading because a
               * later look failed, which is a worse answer than an old one that
               * admits how old it is.
               */
              <p className="ub-failed" role="status">
                {detail}
              </p>
            ) : null}

            {/* See {@link footNote}: a sentence only in the states that have
                stopped, and nothing at all in the ordinary one. */}
            {foot === null ? null : <p className="ub-foot">{foot}</p>}

            {/*
              The one control in this component, and the only state that has one.

              He deleted `Check now` in as many words — *"usage should appear on
              its own, not need a click"* — and that judgement is honoured
              everywhere the automatic path is still trying: there is nothing to
              press, and the sentence above says why there is nothing to press.

              This is the state that judgement did not cover. The app has asked,
              been answered, and stopped; leaving the reader with a sentence and no
              way to act on it is the dead end the whole review was about, and it
              is worse than the button ever was. So the button comes back here and
              only here — after a stop, next to the reason for the stop.

              It is the only thing that reaches past a settled answer:
              `refreshUsage` in the main process remembers "this login has no
              subscription limits" against the account and declines every automatic
              attempt on it, and only a press clears that.
            */}
            {retryOffered(blocked, onCheck) ? (
              <button type="button" className="ub-retry" onClick={onCheck}>
                Check again
              </button>
            ) : null}
            </>
          )}
        </div>
      )}
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
  /**
   * Which computer the session is on. **Absent means this one**, exactly as it
   * does for the controls beside this — see `SessionControls.tsx`.
   *
   * The controls take it to route a request to the far machine. This takes it to
   * refuse to make one: both readings on this bar are read here, so over a
   * session that is not here they are readings of a different computer. The
   * argument, the wording and what a version that could genuinely ask the far
   * machine would need are all in `usage-reach.ts`.
   */
  target?: ControlsTarget
}

export function UsageBar({ sessionId, provider, fit = 'full', bridge, now, target }: UsageBarProps) {
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
  const usage = useUsageBar(sessionId, bridge, target)
  const clock = now ?? Date.now()

  /*
   * The context window, read for free and kept current with no timer.
   *
   * A second hook rather than a field on the first, because the two readings
   * have nothing in common but the bar they land on: one is pushed to every
   * session on a login when any of them learns something, and the other is a
   * file this session's own agent is writing. `useContextWindow` says which
   * events it re-reads on and why none of them is a clock.
   *
   * This replaces `useAutoUsage`, deleted on 2026-08-19 with the file it lived
   * in. That hook existed to keep the *plan* figure fresh off the session's own
   * output, which meant a 725 MB Claude Code boot on a debounce; the figure it
   * kept fresh is now behind the icon and is refreshed by the icon being
   * pressed. What is left is this, which starts nothing.
   */
  const context = useContextWindow(sessionId, bridge, target)

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
      withheld={usage.withheld}
      fetching={usage.checking}
      blocked={usage.blocked}
      noLimits={usage.noLimits}
      detail={usage.detail}
      failed={usage.failed}
      /*
       * The press, and the only caller that passes `force`.
       *
       * Spelled as a lambda rather than handed `usage.check` directly, because
       * `check` takes an optional flag and React would call it with the click
       * event — which is truthy, so every automatic-looking path that ever
       * reached it would quietly become a forced one. The one place a press is
       * meant to override a settled answer is here, deliberately, in view of the
       * sentence explaining what it is overriding.
       */
      onCheck={() => usage.check(true)}
      context={context}
      /*
       * Opening the panel is the refresh, and it is not `force`.
       *
       * `force` is what reaches past a login that has settled on "no
       * subscription limits" and is reserved for the retry button inside the
       * panel, in view of the sentence explaining what it overrides. An open is
       * a look, not an override — and the main process holds the only restraint
       * that matters anyway, one probe per login per minute against the
       * account, so an open on a login another pane refreshed a moment ago
       * costs a file read and nothing else.
       *
       * Gated on the feature the same way the fetcher used to be: a switched-off
       * usage control must stop *acting*, not merely stop being drawn.
       */
      onOpen={usage.canCheck && features.controlOn('chrome.usage') ? () => usage.check() : undefined}
      now={clock}
      anchor={anchor}
    />
  )
}
