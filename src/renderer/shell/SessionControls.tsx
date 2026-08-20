import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
  type RefObject,
} from 'react'
import type { ProviderId } from '@shared/types'
import { ControlPicker } from '../chat/controls/ControlPicker'
import { ControlSection } from '../chat/controls/ControlSection'
import { ControlToggleItem } from '../chat/controls/ControlToggle'
import { menuSide, type MenuSide } from '../chat/controls/menu-side'
import {
  controlName,
  displayValue,
  modelOptions,
  optionsFor,
  previousModelOptions,
  reachOf,
  shortModelLabel,
  type ControlId,
  type ControlOption,
} from '../chat/controls/catalog'
import { runningProvider, useAgentPresence } from './agent-presence'
import type { ControlsTarget } from './controls-target'
import {
  chooseLayout,
  clampWidth,
  measureRoom,
  naturalWidth,
  type ClusterLayout,
  type LayoutNeeds,
} from './control-room'
import { useOneMenu } from './one-menu'
import { panelSpec } from './panels'
import { UsageBar, type UsageFit } from './UsageBar'
import { rowDetail, useConnectors } from './use-connectors'
import { useSessionControls } from './useSessionControls'
import '../chat/controls/AgentControls.css'
import './SessionControls.css'

/**
 * One session's controls, in the chrome: usage, model, effort, fast mode,
 * connectors.
 *
 * ## What this is answering
 *
 * Asad, twice, the second time with the first ask quoted back:
 *
 *   > *"The thing I'm still missing is the other things I asked you to bring
 *   > there — for example the model selection, all of the things that a chat
 *   > session used to have. I mean efforts, fast mode, model selection, and add
 *   > plugin connectors. … But they should be on the top bar."*
 *
 * They existed, and they were in the one place that does not help: folded into
 * the chat composer. A session drawn as a terminal — which is how this app opens
 * every session — has no composer on screen at all, so the model could not be
 * seen, let alone changed, without switching the whole pane to Chat first.
 *
 * ## One component, two homes, and why that is the whole design
 *
 * These are **per-session facts**. The window's bar carries them for the session
 * the window is looking at; each pane of a split carries its own set for its own
 * session, in that pane's own bar, over that pane's own terminal. Both are this
 * component, mounted twice, each with its own `sessionId` — which is what makes
 * the answer to "which session is this the model of" the same as the answer to
 * "which terminal is it drawn over". Writing a toolbar version and a pane
 * version would be two spellings of one control, and the first thing they would
 * disagree about is exactly that question, which is the confusion the split
 * chrome was reorganised to end.
 *
 * ## Everything here is typed at the session
 *
 * There is no API client in this app. `/model`, `/effort` and `/fast` are typed
 * into the pty the way a person sitting at that terminal would type them, under
 * the protocol in `src/main/agent-controls.ts`: refuse unless the composer is
 * empty, write the command *without* the return, wait for the screen to echo it
 * back, and only then commit. So a control here is honest exactly when a person
 * could have done the same thing at the keyboard — and where they could not, it
 * is drawn back and says why, in the main process's own words rather than in a
 * second set invented here.
 *
 * ## The one thing here that is a reading rather than a control
 *
 * The usage bar. Asad asked for it twice — *"where we show the account, next to
 * it we show a bar of the five-hour limit — how much limit is completed, how
 * much is left, with the time of renewal"*, and later, listing what was still
 * missing, *"and also bring that usage bar"* — and it had the same problem the
 * pickers had and worse: it existed, it worked, and it was drawn only inside the
 * chat composer's Options panel, so a terminal session could not reach it at all
 * and a chat session had to open a panel first. It is here for the same reason
 * everything else here is: this is the bar a running session is actually looked
 * at from, and the account it is a reading *of* is stated on this same bar.
 *
 * It behaves differently from its neighbours in exactly one respect, and the
 * difference is the point — see the fold below. A control that is folded away is
 * still reachable through the panel that folded it. A reading that is folded
 * away is indistinguishable from a reading that does not exist, which is the one
 * confusion this feature cannot afford. So `UsageBar` stays on screen at every
 * width and shortens itself instead.
 *
 * ## What is deliberately not in this cluster
 *
 * **Permission mode.** It was left out, then put in when the composer's control
 * row was removed and it turned out to be the one control with no twin up here,
 * and it is out again — because the CLI prints `⏵⏵ bypass permissions on
 * (shift+tab to cycle)` along the bottom of every session it runs, and a second
 * place to read one fact is a second place that can disagree. All three turns of
 * that argument are at `CHROME_CONTROLS`, in order.
 *
 * **Slash commands.** *"Maybe slash commands also somehow — maybe not now,
 * maybe later."* Not now. Nothing here enumerates them and nothing pretends to.
 */

export interface SessionControlsProps {
  /** The pty these act on. Each mounted cluster owns exactly one. */
  sessionId: string
  /** The session's working directory, which is where its transcript is read from. */
  cwd?: string | null
  /**
   * What this app **launched** into the session — a record of the spawn, and
   * deliberately not the same question as what is in front of it now.
   *
   * `shell` withdraws the whole cluster, but only once the screen agrees: a
   * `/bin/zsh -l` has no model, no effort and no fast mode, and the reader
   * behind these values falls back to Claude Code's own settings file when it
   * cannot parse a screen — which is how a plain shell once came to report
   * `Model  Opus 5`. `finish.test.ts` pins that behaviour for the composer's
   * copy and it is the same fact here. What the record cannot settle on its own
   * is the case in {@link exited}'s note below, and the component resolves it
   * through `runningProvider`.
   *
   * `codex` and `gemini` do **not** withdraw it. They get the chips, drawn back
   * and carrying the sentence explaining that this build has not been shown how
   * those CLIs change a model at runtime — because those sessions genuinely have
   * a model, and a gap where a control should be says nothing about why.
   */
  provider?: ProviderId
  /**
   * Whether the pty is gone — `exitCode !== null` on the session record.
   *
   * ## Why a fourth prop, and why it is required
   *
   * Everything else here is about a *live* session, and this cluster used to be
   * able to ignore the question because it never asked the screen anything. It
   * asks now, through {@link useAgentPresence}, and the screen is exactly the
   * source that can go on saying "Claude Code" about a session whose process is
   * already dead: a CLI killed rather than `/exit`-ed does not clear its own
   * banner, so the last frame of a corpse still carries every marker the reader
   * matches on. Presence answers that from the record first — `exited` is the
   * first thing `presenceFromSession` looks at — which is why the honest value
   * has to arrive rather than being assumed.
   *
   * Required, with no default, and that is the whole point of it. A `= false`
   * here would be a fabrication with a visible consequence — live, pressable
   * model and effort chips drawn over a session that cannot be typed into at
   * all — and it would be invisible at every call site, because the caller that
   * forgot it would compile. `renderer/wiring.test.ts` pins that both mounts in
   * `App.tsx` pass the session's real exit code and not a literal.
   */
  exited: boolean
  /**
   * Opens the app's MCP servers view — the one connector surface it has.
   *
   * Null when that view is not installed in this build, in which case the chip
   * is drawn back and says so rather than disappearing.
   */
  onOpenConnectors: (() => void) | null
  /**
   * Which computer the session is on. **Absent means this one**, which is what
   * every mount of this cluster meant before the prop existed.
   *
   * ## Why one prop and not a different component
   *
   * Asad, three times, the last on 2026-08-18: *"I don't see it in server
   * sessions and in the remote sessions both."* The reason he could not was
   * never that these controls are a local idea — it was that both hooks behind
   * them called an IPC channel that reaches this machine's `PtyManager` by this
   * machine's session id, so over a session on a paired PC they asked about a
   * session that does not exist here. `controls-target.ts` is the router that
   * fixes the address; this prop is the address.
   *
   * Everything else about the cluster is deliberately unchanged. His words were
   * *"the same identical options for the remote sessions too"*, and identical
   * means the same component, the same chips, the same fold, the same menus —
   * not a second cluster that looks similar and drifts.
   *
   * The one thing that *does* change with it is the connectors chip. See
   * {@link hasConnectors} below: MCP servers are resolved from a folder on this
   * computer, and a session on another one has none here to resolve.
   */
  target?: ControlsTarget
}

/**
 * The controls this cluster carries, in the order they are worn.
 *
 * Model first because it is the one that changes per task and the one he named
 * first. Fast mode last because it is the one that most often has nothing to
 * report — see `unreadLabel` in `catalog.ts`.
 *
 * ## Permission mode was here, and is not any more
 *
 * It arrived because the composer's control row was deleted and it was the one
 * control on that row with no twin up here — *"Options is showing the same
 * options that we already have here… remove them from the chat box side
 * completely"* — so leaving it out then would have deleted a working control as
 * a side effect of removing duplicates of other ones. That was the right call
 * with the information of the day. What it produced on screen was a chip
 * reading `Bypass`, and Asad, looking at it:
 *
 *   > *"we don't need this part also at the end, now bypass read things because
 *   > we have this here already inside."*
 *
 * "Here already inside" is the terminal directly underneath this bar, and it is
 * not an approximation of the fact — it *is* the fact. Claude Code draws its own
 * permission mode along the bottom of every session for as long as the session
 * is running:
 *
 *     ⏵⏵ bypass permissions on (shift+tab to cycle)
 *
 * captured verbatim in `src/main/cli-screens.capture.json` and asserted in
 * `AccountChip.test.tsx` and `SessionControls.presence.test.tsx`. That line is
 * the CLI's, it is always current because the CLI redraws it, and it names the
 * gesture that changes it in the same breath.
 *
 * So what this chip was is a **second place to read one fact** — and the second
 * place is the one that can be wrong. Everything else in this cluster is scraped
 * off the same screen, which means this chip could only ever be as fresh as the
 * last frame this app parsed, while the line two inches below it is redrawn by
 * the process itself. Two readings of one thing that can disagree is worse than
 * one reading, and the one to keep is obviously the CLI's.
 *
 * It is a removal from the *chrome*, not from the app: the mode is still read
 * (`readings.permission` is still parsed off the wire and still mirrored in
 * `ControlsReading`), it is still displayed by the CLI, and it is still
 * changeable — with shift+tab, in the terminal, which is where every other
 * keystroke this cluster sends ends up anyway. `chat/controls/one-home.test.ts`
 * carries the whole of that argument as an assertion, so a future reader who
 * thinks this was an oversight finds out otherwise from a failing test rather
 * than from a comment they did not open.
 */
const CHROME_CONTROLS: readonly ControlId[] = ['model', 'effort', 'fast']

/**
 * Which controls do not get a chip of their own, and whose menu they end.
 *
 * Asad, on the bar: *"move fast mode toggle inside the models dropdown at the
 * end."*
 *
 * The pairing is not arbitrary and the map is written host-first so that it
 * reads as the sentence it is: the model menu ends with fast mode. They are
 * coupled in the CLI itself — its model picker prints *"Switching to other
 * models turns off fast mode"* under its own rows — so a switch that lives
 * anywhere else puts the consequence at one end of a toolbar and the cause at
 * the other. What it looks like, and the four things that stop it reading as a
 * twelfth model, are argued at `ControlToggleItem` in
 * `chat/controls/ControlToggle.tsx`.
 *
 * This is a fact about *placement*, so it lives here beside the list of what is
 * on the bar at all, and not in `catalog.ts` — which held two such lists once,
 * `PRIMARY_CONTROLS` and `MENU_CONTROLS`, and is the better for having lost
 * them. The tombstone in that file explains why: a catalogue that also lays out
 * a toolbar goes stale about a surface it cannot see.
 *
 * A nested control is still `CHROME_CONTROLS`'s. It is this cluster's to draw,
 * it is named in the folded chip's hover label by `contentsSentence`, and it
 * keeps its own full section in the folded panel — where there is room for a
 * heading and a description, and where nesting it inside another section would
 * buy nothing. `chat/controls/one-home.test.ts` asks only that every control be
 * reachable somewhere, which is what moving it one level deeper preserves.
 */
const NESTED_CONTROLS: Partial<Record<ControlId, ControlId>> = { model: 'fast' }

/**
 * The controls that get a chip on the open bar: everything in the cluster that
 * is not drawn inside something else.
 *
 * Derived rather than typed out a second time. Two hand-written lists that have
 * to agree is how a control gets drawn twice — or, once somebody edits the
 * shorter one, not at all — and this cluster has already been reported for both
 * failures, from opposite directions.
 */
const NESTED = new Set<ControlId>(Object.values(NESTED_CONTROLS))
const ROW_CONTROLS: readonly ControlId[] = CHROME_CONTROLS.filter((id) => !NESTED.has(id))

/**
 * What to believe about the row's own width until it has been measured once.
 *
 * ## Where these two numbers come from
 *
 * Both were read off a rendered row on 2026-08-19, in Chrome, through
 * `.harness/controls.html` — the page written for this, which mounts this
 * component inside `WindowToolbar`'s own skeleton and reports `naturalWidth`
 * (the very function that overwrites these) against a bar whose width the
 * measurement sweeps. The session it draws is the ordinary working one: `Opus
 * 5`, `Extra high`, fast mode `Off`, the usage element carrying a context figure
 * of `154.1k` — the live reading this app took off its own transcript that day —
 * and the connectors chip.
 *
 * Re-measured twice more the same day — once after the usage element was split
 * into a context figure and a plan icon, and once after the fast-mode chip left
 * the bar for the end of the model menu. What the latest sweep printed, per bar
 * width:
 *
 * | bar | clamp | layout | fit | row |
 * |---|---|---|---|---|
 * | 1400 | 760 | full | full | **318.5** |
 * | 1200 | 560 | full | full | **318.5** |
 * | 900 | 260 | folded | full | **206.8** |
 * | 800 | 160 | folded | full | **140.6** |
 * | 760 | 120 | folded | tight | **104.4** |
 * | 720 | 106 | folded | tight | **104.4** |
 *
 * ## What that says about the numbers this replaces
 *
 * They were `{ full: 363, folded: 207 }`, and only the first has moved.
 *
 * `full` lost the fast-mode chip: *"move fast mode toggle inside the models
 * dropdown at the end."* The sweep behind the previous number broke the open
 * row into its chips — `69.3 + 85.0 + 42.0 + 91.7` for model, effort, fast mode
 * and connectors — so the chip that left was 42.0 wide, and with the row's 2px
 * gap that is 44.0. 362.5 − 44.0 is 318.5, and the measurement says 318.5.
 * Written down because the agreement is the check and not the source:
 * arithmetic on a measurement is not a measurement, and only the sweep can say
 * what the row actually wants.
 *
 * `folded` does not move at all, and that is the expected answer rather than a
 * suspicious one. The folded chip never drew fast mode — the note beside it
 * says so in as many words, *"what folds away entirely is fast mode"* — so
 * there was nothing there for this change to take away. A `folded` that had
 * shifted would have meant the fold was drawing something it says it does not.
 *
 * The generation before that was `{ full: 473, folded: 318 }`, against a usage
 * element that drew two named windows, two percentages, two meters and a
 * renewal clause — 177.6 pixels of it, against 64.6 now.
 *
 * `folded` is written as the **widest** of the folded tiers rather than the
 * narrowest. The folded arrangement does not have one width — the summary chip
 * gives up its second value, then its words — so a single constant can only be a
 * bound, and the bound worth holding is the high one, for `naturalWidth`'s own
 * stated reason: an under-measured row is the one that unfolds into a bar it
 * overflows.
 *
 * It also, today, changes nothing: `chooseLayout` reads `needs.full` and never
 * `needs.folded`, and the only caller of `drawnWidth` — the function that does
 * read it — is `control-room.test.ts`, with its own fixture. Said plainly rather
 * than left for a reader to discover, because a constant that looks load-bearing
 * and is not is how a wrong number survives review.
 *
 * ## The mode switch shrank on the same day, and these did not move
 *
 * It became two icon buttons instead of three words — about 50px where there
 * were about 180 — and the sweep was run again for it, through the same page,
 * printing 318.5 at 1400 and 104.4 at 720. Byte for byte the numbers above.
 *
 * That is the expected answer rather than a suspicious one, and the reason is
 * worth writing down because the temptation is to "correct" these by 130: the
 * mode switch is not *in* the cluster. It is a sibling on the same bar, and
 * `roomFor` charges it live off the DOM — so what its slimming actually buys is
 * 130 more pixels of `room`, which moves the width at which this row folds
 * without moving what the row itself wants. Adjusting these by hand for it would
 * have been arithmetic on the wrong box.
 *
 * ## And they are still only a starting point
 *
 * `naturalWidth` replaces each with the real thing on the first paint that draws
 * it, because the true width moves with its own contents. `Opus 5` and `Opus 5
 * (1M context)` are not the same chip, and a constant that pretends otherwise is
 * a constant that was right on the day it was written. What a stale guess
 * actually costs is one frame — an unnecessary fold, or an unnecessary unfold,
 * before the first measurement lands — which is why these are worth keeping
 * honest and not worth agonising over.
 *
 * This is the whole of what remains of `FOLD_BELOW_PX`, the single 900px
 * threshold this replaced. That number compared the wrong box — see
 * `control-room.ts`, which has the full account — and one number could never
 * have described both a 1176px window toolbar carrying a mode switch and a
 * 124px guest-pane bar carrying a close button.
 */
const FIRST_GUESS: LayoutNeeds = { full: 319, folded: 207 }

/**
 * Below this much room, the usage element folds its icon into its figure.
 *
 * The one width decision that element still has, and it replaces the two
 * thresholds — 380 and 120 — that the old three-tier reading needed. Those were
 * about a renewal clause and a pair of meters, and both are inside the dropdown
 * since Asad's *"no lets keep it in the dropdown and keep context outside"*.
 * What is left on the bar is a figure and a 21-pixel icon, and the only question
 * a width can still decide is whether both of them fit.
 *
 * 145 is measured through `.harness/controls.html` on 2026-08-19, by sweeping
 * the bar a pixel at a time across the boundary and reading the row's overflow:
 *
 * | clamp | fit | usage | **row wants** | overflows |
 * |---|---|---|---|---|
 * | 150 | full | 64.6 | **140.6** | no |
 * | 145 | full | 64.6 | **140.6** | no |
 * | 144 | tight | 30.4 | **104.4** | no |
 * | 106 | tight | 30.4 | **104.4** | no |
 *
 * So the folded row with both elements on it wants 140.6, and 145 is that with
 * a little over four pixels to spare. Below it the icon folds into the figure
 * and the row drops to 104.4, which fits inside the 106 that the app's own
 * 720-pixel minimum window leaves this cluster.
 *
 * The wrong version of this number is not a rounding error: at the previous
 * threshold the 720px window drew a row 27 pixels past its own edge, measured,
 * with the folded controls chip clipped by exactly that much.
 */
const TIGHT_BELOW_PX = 145

/**
 * Which arrangement of this cluster fits the bar it is in, kept current.
 *
 * The nearest `<header>` is the bar in both homes — `WindowToolbar` renders
 * `<header class="toolbar">` and `PaneBar` renders `<header class="pane-cell-head">`
 * — so this reads the right element in both without either component having to
 * be told which one it is, and without this file knowing either class name.
 * What it does with that element is in `control-room.ts`: walk out from the
 * cluster to the bar, charge every caption its protected share and every
 * control its full width, and hand back what is left.
 *
 * Starts full. There is no DOM in this project's tests, so nothing here runs
 * there and the static render is the whole row, which is the state worth
 * asserting; in the app the first measurement lands before the first paint.
 *
 * ## Why the bar is found by a *callback* ref
 *
 * The first version read `hostRef.current?.closest('header')` inside a mount
 * effect, and it was wrong in the way that only shows up in the app: the window
 * toolbar's cluster folded correctly at every width and a split pane's cluster
 * never folded at all, so at 568px the four chips squashed into the folder and
 * the account beside them and the words overlapped. Caught by looking, not by
 * any test — both clusters are the same component and the same code path, and
 * the difference was a race, not a branch.
 *
 * A callback ref removes the race by construction rather than by timing: React
 * calls it with the node at the moment the node is attached and with `null` when
 * it goes, so there is no window in which this asks a ref that has not been
 * filled in yet. Putting the bar in state then makes the observer effect depend
 * on the element itself, which also means a cluster that is moved from one bar
 * to another — every time a split opens or closes — re-observes the bar it is
 * actually in rather than the one it was born in.
 *
 * ## What is watched, and why it is more than the bar
 *
 * Three kinds of thing move the answer, and only one of them is the bar
 * resizing. A session renamed from `Session 4` to a sentence changes what the
 * heading wants without changing the bar by a pixel; a model finally reading
 * back as `Opus 5 (1M context)` changes what the row needs the same way. So the
 * observer takes the bar, each of the bar's own children, and this cluster —
 * which between them see a window resize, a divider drag, a rename and a
 * reading arriving.
 *
 * Watching the cluster itself is the one that looks like a loop and is not.
 * Every term the room is computed from is independent of how wide the cluster
 * currently is, so folding changes the cluster, wakes the observer, and
 * produces the identical answer; React sees the same state and stops. That
 * invariance is argued in full in `control-room.ts`, and it is the reason this
 * can watch its own size at all.
 */
function useClusterFit(
  host: RefObject<HTMLDivElement | null>,
  /** Anything about the contents that changes what the row needs. */
  signature: string,
): {
  layout: ClusterLayout
  /** How wide the cluster may be drawn before it covers a control. */
  clamp: number | null
  attach: (node: HTMLDivElement | null) => void
} {
  const [layout, setLayout] = useState<ClusterLayout>('full')
  const [clamp, setClamp] = useState<number | null>(null)
  const [bar, setBar] = useState<HTMLElement | null>(null)
  // Read and written inside the observer, which must not re-subscribe when the
  // layout changes — and `layout` in a closure would be the value from the
  // render that installed the observer, which is exactly one fold behind.
  const drawn = useRef<ClusterLayout>('full')
  const needs = useRef<LayoutNeeds>(FIRST_GUESS)

  const attach = useCallback(
    (node: HTMLDivElement | null): void => {
      // The object ref is still wanted for the outside-click test, which asks
      // "is the click inside this cluster" and has no interest in the bar.
      host.current = node
      setBar(node ? node.closest('header') : null)
    },
    [host],
  )

  const measure = useCallback((): void => {
    const cluster = host.current
    if (!cluster || !bar) return
    /*
     * Only a row that is not being squeezed can say how wide it wants to be —
     * see `naturalWidth`. When it cannot, the last honest figure stands.
     *
     * Whichever arrangement is on screen is the one that gets measured, and the
     * other keeps its last figure. The case that leaves behind is narrow and
     * self-correcting: a model name that grows a lot *while the row is folded*
     * leaves `full` remembering a smaller row than it would now be, so an
     * unfold can happen a few pixels early — at which point the full row is on
     * screen, gets measured for real, and folds back. One frame, in a bar
     * sitting on its own threshold.
     */
    const measured = naturalWidth(cluster)
    if (measured !== null) needs.current = { ...needs.current, [drawn.current]: measured }
    const room = measureRoom(cluster, bar)
    const next = chooseLayout(room, needs.current, drawn.current)
    drawn.current = next
    setLayout(next)
    setClamp(Math.round(clampWidth(room)))
  }, [bar, host])

  /*
   * Before the paint, not after it.
   *
   * A cluster mounted into a bar too narrow for it would otherwise be drawn
   * once at its full width — over the mode switch, or over a pane's close
   * button — and folded on the next frame. One frame is enough to see, and it
   * is the frame every split opens on. `useEffect` on the server only because
   * `useLayoutEffect` warns there and this component is rendered to a string by
   * its own tests.
   */
  const beforePaint = typeof window === 'undefined' ? useEffect : useLayoutEffect
  beforePaint(() => {
    if (!bar || typeof ResizeObserver === 'undefined') return
    measure()
    const observer = new ResizeObserver(measure)
    observer.observe(bar)
    for (const child of bar.children) if (child instanceof HTMLElement) observer.observe(child)
    if (host.current) observer.observe(host.current)
    return () => observer.disconnect()
  }, [bar, host, measure])

  // A reading arriving, or a provider changing, resizes nothing on its own —
  // the chip it lands in was already that wide or is about to be, and the
  // observer only hears about the second case.
  useEffect(measure, [measure, signature])

  return { layout, clamp, attach }
}

/**
 * How much of itself the folded chip is allowed to say.
 *
 * ## What this is answering
 *
 * The chip used to have one shape and a fade: both values, laid out at their
 * natural widths, with a mask over the trailing sixteen pixels for whatever ran
 * past the edge. Measured in the running app on 2026-08-18, on a session named
 * *"Update Claude Code terminal to new version"*:
 *
 * | window | chip | label drawn | of |
 * |---|---|---|---|
 * | 720 (the app's own `minWidth`) | 25px | **0px** | 106px |
 * | 900 | 92px | 45px | 106px |
 * | 1100 | 137px | 106px | 106px |
 *
 * So at the narrowest window a person can actually make, the control was a bare
 * chevron with a hundred and six pixels of invisible text behind it, and at 900
 * it read `Opus 5 · Ul` dissolving into the toolbar. That second one is the
 * *"faded, clipped text — show it properly or make it a dropdown only"* item
 * from the 2026-08-17 review, arrived in a new place; the first is neither of
 * the two things he offered.
 *
 * ## Three states, and none of them is a fade
 *
 * - **`both`** — `Opus 5 · Ultracode`. What the chip has always meant to be.
 * - **`model`** — `Opus 5` alone. The value he singled out — *"just Opus 5 with
 *   drop down is good enough"* — drawn whole, rather than both values drawn
 *   half. Dropping the effort here is not the mistake `catalog.ts` warns about:
 *   nothing is being hidden that the reader cannot get back, because the chip's
 *   own hover label names every control behind it and quotes both readings, and
 *   the panel is one press away.
 * - **`glyph`** — the sliders mark and the caret, and no words at all. This is
 *   the honest version of the 25-pixel chip above: a toolbar button that has
 *   decided to be an icon, rather than a label that has been faded to nothing.
 *
 * ## Why this is decided from the room and not from the overflow
 *
 * Because the overflow is a fact about what is drawn, and what is drawn is what
 * this decides. Measuring "do both values fit" and then removing one to make
 * them fit changes the answer to the question that was just asked, and a
 * component that re-measures on its own output oscillates. {@link clampWidth}
 * cannot: it is computed from the cluster's *siblings* on the bar, so it is the
 * same number whichever of the three states is on screen. `fit` next door is
 * decided the same way for the same reason.
 *
 * ## Where the two numbers come from
 *
 * Both measured in the app, with the reading beside the chip at its own natural
 * width for the tier it is in.
 *
 *  - **250** is what `both` costs: the reading is 107 at `dense`, the gap is 2,
 *    and the chip carrying `Opus 5 · Ultracode` is 137 — 31 of chrome (16 of
 *    padding, a 6 gap, a 9 caret) around 106 of words. 246, rounded up to a
 *    number that is not sitting on its own boundary.
 *  - **100** is what `model` costs at the bottom of the range, where the reading
 *    has already collapsed to its two percentages and measures 35: 35 + 2 + 69,
 *    the 69 being the same 31 of chrome around `Opus 5`. 106, and the threshold
 *    is set below it so that {@link MIN_CLUSTER_PX} — which is exactly 106, and
 *    was raised to it for this — lands inside `model` rather than on its edge.
 *
 * A longer model name than `Opus 5` does not break either number, it truncates:
 * the last value on the chip ellipsises, which is a mark a reader recognises as
 * "there is more", where a fade is a mark that the screen has gone wrong.
 */
export type SummaryDetail = 'both' | 'model' | 'glyph'

export const SUMMARY_BOTH_PX = 250
export const SUMMARY_MODEL_PX = 100

export function summaryDetail(clamp: number | null): SummaryDetail {
  // Nothing measured yet is the unclamped row, which is what the first paint
  // should draw and what this component's own tests render — the same answer
  // `fit` gives to the same state.
  if (clamp === null || clamp >= SUMMARY_BOTH_PX) return 'both'
  return clamp >= SUMMARY_MODEL_PX ? 'model' : 'glyph'
}

/**
 * A sentence naming what is in the cluster, built from the cluster's contents.
 *
 * Exported so the tests can assert that the folded chip advertises every
 * control behind it. Hand-typing that sentence is how a hover label comes to
 * name a control that was deleted six months earlier, and this app has already
 * lost controls behind an unnamed button once — the whole account is in
 * `catalog.ts`, in the block that stands where `PRIMARY_CONTROLS` and
 * `MENU_CONTROLS` used to be. Named as a tombstone rather than as a symbol
 * because that is what it is now: the lists are deleted and the argument they
 * carried is what was kept.
 */
export function contentsSentence(withConnectors: boolean): string {
  const names = [...CHROME_CONTROLS.map(controlName), ...(withConnectors ? ['Connectors'] : [])]
  return names
    .map((name, index) => (index === 0 ? name : name.toLowerCase()))
    .reduce((sentence, name, index) => (index === names.length - 1 ? `${sentence} and ${name}` : `${sentence}, ${name}`))
}

/**
 * The folded chip's hover label, which is also what a screen reader is told.
 *
 * It names every control behind the chip and then states the two values that
 * are on it, so nothing on the bar is a value without a name and nothing behind
 * the fold is a control without a mention. Both readings are quoted whole — the
 * chip itself truncates a long model name to fourteen characters, and this is
 * where the rest of it lives.
 *
 * This carries more weight than it did. Since the names came off the chips —
 * *"no need to tell that Model Opus 5 — just Opus 5 with drop down"* — this
 * sentence is the only place on the closed bar where the words "model" and
 * "effort" appear at all, which is exactly why it names the value as well as
 * quoting it: `Opus 5` alone is a fact with no subject.
 *
 * A function rather than a template in the JSX so that a test can hold it to
 * that, without a DOM and without grepping the file: the failure it guards is a
 * label that stops naming something the chip is still hiding.
 */
export function summaryLabel(
  modelValue: string,
  effortValue: string,
  withConnectors: boolean,
): string {
  return `${contentsSentence(withConnectors)} — model ${modelValue}, effort ${effortValue}`
}

const CARET = 'M2.5 4.5 6 8l3.5-3.5'

/**
 * The connectors chip, which exists only when there are connectors.
 *
 * ## What this is answering
 *
 * Asad: *"connectors — a dropdown only when some exist. Hide it when empty."*
 *
 * It used to be a door, unconditionally: a chip that opened the MCP servers
 * view whether or not a single server was configured. On a machine with none —
 * which is every machine on its first day — that is a permanent invitation to
 * an empty room, holding a chip's width on a bar shared with five other
 * controls. It is the most repeated finding in his whole review, and the fix is
 * the one he stated rather than a softening of it: the chip is not greyed out
 * when there is nothing behind it, it is **not there**.
 *
 * ## Why the rows are a list and not a menu
 *
 * Because there is exactly one thing this app can do with a server from a
 * toolbar, and it is not per-server. `onOpenConnectors` opens the MCP servers
 * view — the surface that already owns adding, inspecting, connecting and
 * explaining every server — and it takes no argument, so a row that was a
 * button would take you to the same place as every other row. That is precisely
 * the fault he reported on another page in the same recording: *"a long list of
 * old sessions … every row opens the same session."*
 *
 * So the rows are what they honestly are — a reading of what this session's
 * directory resolves to, name and scope and transport, and the CLI's own
 * sentence for one it would skip — and the single action sits under them, once.
 * Nothing here hovers, because nothing here is clickable.
 *
 * The rows come from `mcp:list`, parsed by the composer's own `readServers`, so
 * this list and the connector list in the chat box cannot come to disagree
 * about what a server is.
 */
export function ConnectorsPicker({
  rows,
  onOpen,
  blocked,
}: {
  rows: readonly { id: string; name: string; enabled: boolean; disabledReason: string | null; scope: string | null; transport: string | null }[]
  onOpen: (() => void) | null
  blocked: string | null
}) {
  const spec = panelSpec('mcp')
  const [open, setOpen] = useState(false)
  const root = useRef<HTMLDivElement>(null)
  const shut = useCallback(() => setOpen(false), [])
  /*
   * Which edge this panel hangs from. It is the third `.ac-menu` in the window
   * and the only one that was not measuring itself — so on a bar where the two
   * pickers beside it had learned to flip, this one still opened off the
   * right-hand edge of the glass. Found by sweeping every chip on the cluster
   * against the viewport after the other two were fixed, which is the only way
   * a third instance of a shared class gets found at all.
   *
   * `menu-side.ts` holds the arithmetic and the sentence that prompted it.
   */
  const [side, setSide] = useState<MenuSide>('left')
  // The window's one-menu-at-a-time rule, the same as every other picker on
  // this bar. Without it, opening this over the model menu leaves two panels
  // overlapping on a bar one row tall — see `one-menu.ts`.
  useOneMenu(open, shut)

  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') setOpen(false)
    }
    const onDown = (event: MouseEvent): void => {
      if (!root.current?.contains(event.target as Node)) setOpen(false)
    }
    document.addEventListener('keydown', onKey)
    document.addEventListener('mousedown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey)
      document.removeEventListener('mousedown', onDown)
    }
  }, [open])

  // Measured on open, before the panel is painted for the first time — the same
  // moment the two pickers on this bar measure themselves.
  useLayoutEffect(() => {
    if (!open) return
    const box = root.current?.getBoundingClientRect()
    if (box) setSide(menuSide(box, window.innerWidth))
  }, [open])

  return (
    <div className="ac-picker sc-connectors" ref={root}>
      <button
        type="button"
        className="cc-chip"
        aria-haspopup="menu"
        aria-expanded={open}
        /* The chip's own word, and nothing after it. It used to append the MCP
           view's blurb — a sentence in a tooltip, on a chip whose label is
           already the noun. Those blurbs are gone; see `shell/panels.ts`. */
        title="Connectors"
        onClick={() => setOpen((was) => !was)}
      >
        <span className="ac-name">Connectors</span>
        <svg className="ac-caret" width="9" height="9" viewBox="0 0 12 12" aria-hidden="true">
          <path d={CARET} fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        </svg>
      </button>

      {open ? (
        <div
          className={`ac-menu sc-connectors-menu${side === 'right' ? ' ac-menu-right' : ''}`}
          role="group"
          aria-label="Connectors"
        >
          {rows.map((row) => (
            <p key={row.id} className="sc-connector" data-off={row.enabled ? undefined : ''}>
              <span className="sc-connector-name">{row.name}</span>
              {/* The CLI's own reason when it would skip this server, and what
                  was actually read of it otherwise. Never both, and never a
                  plausible stand-in for a field the list did not carry — see
                  `readServers`. */}
              <span className="sc-connector-detail">{rowDetail(row)}</span>
            </p>
          ))}
          <div className="sc-sheet-actions">
            <button
              type="button"
              className="sc-open"
              disabled={onOpen === null}
              title={
                onOpen === null
                  ? 'The MCP servers view is not installed in this build, so there is nowhere for this to open.'
                  : `Open ${spec.label}`
              }
              onClick={() => {
                setOpen(false)
                onOpen?.()
              }}
            >
              {blocked === null ? `Open ${spec.label}` : 'Not available in this build'}
            </button>
          </div>
        </div>
      ) : null}
    </div>
  )
}

/**
 * Why this cluster has nothing to offer a session running some other agent.
 *
 * ## Why the sentence is composed here rather than quoted from the catalogue
 *
 * It used to be `unsupportedProviderNote` in `chat/controls/catalog.ts`, and
 * quoting it was deliberate: the rule `blockedFor` follows a few hundred lines
 * below is that the reason shown *before* a click is the same string the far
 * end returns *after* one, so the two cannot drift. That rule still stands.
 * This one string is the exception, and the reason is what it said:
 *
 *   > *"These work by typing Claude Code's own commands into the session."*
 *
 * That sentence is only ever drawn on a session that is **not** running Claude
 * Code. It is the note the Codex and Gemini bars get and no other bar gets it,
 * so the one person guaranteed not to be using that vendor was the only person
 * being shown its name — which is Asad's complaint about vendor names in copy,
 * in its purest available form. A screen that serves every agent does not carry
 * one agent's name; a row that *is* that agent may.
 *
 * The catalogue is the wrong place to correct it, and that is not a technicality.
 * Every option in `catalog.ts` is one CLI's slash-command grammar — `/model`,
 * `/effort`, the permission modes read back off that CLI's own settings file —
 * so a module that named it in its own doc comment would be describing itself
 * accurately. This sentence is not about the controls. It is about the *bar*,
 * and about who is standing in front of it, and that question is this file's.
 *
 * ## What it says instead
 *
 * The same three facts with the category where the vendor was: these work by
 * typing one CLI's own commands; the agent in this session has its own; this
 * build has not been shown what they are. "Has not been shown" rather than
 * "cannot" for the reason the catalogue argued and which has not changed —
 * both were looked at on the machine this was written on and neither could be
 * driven (the Codex install's vendored binary was missing, the Gemini CLI stops
 * on an unanswered authentication picker), so calling them incapable would be
 * inventing a fact in order to sound final.
 *
 * The running agent's own name stays. Naming the thing a row *is* is the half
 * of the rule that was never in question, and "Codex has its own" is a good
 * deal more use to the person reading it than "the other one has its own".
 *
 * ## And the two different nulls
 *
 * `claude` and a CLI this app never saw both get their controls drawn: the far
 * end is the authority there, and `refuseByProvider` in
 * `src/main/agent-controls.ts` reads the session's screen and refuses if the
 * guess was wrong, which is a better answer than withdrawing a control on a
 * suspicion. `shell` never reaches this function at all — the cluster returns
 * null for a bare shell well before `blockedFor` exists — and that is why there
 * is no shell branch here to keep in step with the one in `catalog.ts`.
 */
function foreignAgentNote(provider: ProviderId | undefined): string | null {
  if (provider !== 'codex' && provider !== 'gemini') return null
  const agent = provider === 'codex' ? 'Codex' : 'Gemini'
  return `These work by typing one CLI’s own commands into the session. ${agent} has its own, and this build has not been shown what they are — so nothing is offered here rather than a button that types the wrong thing.`
}

export function SessionControls({
  sessionId,
  cwd,
  provider,
  exited,
  onOpenConnectors,
  target,
}: SessionControlsProps) {
  const host = useRef<HTMLDivElement>(null)
  const [open, setOpen] = useState(false)
  /**
   * Is there an agent in front of this session, whatever it was launched as.
   *
   * ## The bug this is the whole of the answer to
   *
   * Asad's Windows recording, 0.4.0. Two sessions, one window, the same width:
   * `ClaudeImza` carried the usage reading, the model chip and the effort chip,
   * and `ClaudeImzacrm` carried none of the three — while the terminal directly
   * underneath the empty bar printed `Claude Code v2.1.224 · Opus 5 with xhigh
   * effort · Claude API`. Not a fold, not a width: a per-session fact, and it
   * held across five frames.
   *
   * The cluster was asking `provider`, which is a record of what this app
   * *spawned*. It says `shell` for a session started as `$SHELL -l` and it goes
   * on saying `shell` for the rest of that session's life — including after
   * somebody types `claude` at the prompt, which is an ordinary thing to do and
   * is a thing this app itself offers to do for you: `AccountChip`'s Run Claude
   * Code button types exactly that command into exactly this kind of session.
   * So the app was arranging the state it then punished.
   *
   * And it already knew better forty pixels away. The account chip on the same
   * bar in the same frame was drawn in its *picker* mode, which `chipMode` only
   * reaches once presence has read the screen and reported `running === true`.
   * One component in that bar had established there was an agent running; its
   * neighbour withdrew anyway. Two components, one question, two sources — that
   * is the fault, and consulting the same source is the fix.
   *
   * Null rather than a session when either half is missing, exactly as
   * `ChatView` does it: presence reads `UNKNOWN_PRESENCE` from a null, and an
   * unknown provider is left alone below rather than being resolved into one.
   */
  const agent = useAgentPresence(sessionId && provider ? { id: sessionId, provider, exited } : null, target)
  /**
   * What to *treat* the session as, which is the only thing below this line
   * that should be consulted.
   *
   * `runningProvider` turns `shell` into `undefined` — "not known" — once the
   * screen has actually said an agent is there, and leaves every other answer
   * untouched. `undefined` is the right word rather than a convenient one: this
   * app never saw which CLI was typed, and `refuseByProvider` in
   * `src/main/agent-controls.ts` is built around that exact absence — it
   * consults the screen, and writes only where the screen carries Claude Code's
   * own markers. So a control drawn from here can act, and one drawn over a
   * session that turns out to hold something else is refused by the far end
   * rather than typing Claude's commands at a stranger.
   *
   * `useSessionControls` is handed this and not the record, or the reading it
   * takes would be refused with *"This session is a shell, not an agent CLI"* —
   * the model chip would draw itself disabled over a running agent, which is
   * the same wrong answer as drawing nothing, only louder.
   *
   * `UsageBar` is handed it too, and what "not known" costs *there* has now
   * moved twice, so it is written down rather than left to be rediscovered.
   * This paragraph used to read:
   *
   *   > *"`auto-usage.ts` types `/usage` into a session by itself and refuses
   *   > to do that for anything but `claude`, so a session whose CLI this app
   *   > never saw does not get that unasked fetch. … typing a slash command
   *   > into a terminal on the strength of a guess about which CLI is in it is
   *   > precisely the thing `undefined` exists to stop."*
   *
   * That was the right trade for as long as a refresh meant typing into
   * somebody's live terminal. It stopped being one on 2026-08-18, when
   * `usage:refresh` became a file read plus, at worst, a four-second `claude`
   * of this app's own in the user's home directory — and from that day the
   * refusal it describes was the bug rather than the caution, because
   * `undefined` is exactly what a shell with `claude` running in it arrives as.
   *
   * `auto-usage.ts` and the gate that lived in it were deleted on 2026-08-19,
   * when Asad settled the whole question — *"no lets keep it in the dropdown
   * and keep context outside"* — so nothing decides on this value's behalf any
   * more: a plan figure is fetched when somebody opens the panel to read it,
   * and the main process's own `mayShareClaude` in `src/main/usage-ipc.ts` is
   * the one gate left. What `undefined` still costs here is nothing, and what
   * is unchanged is the half that was never about cost: nothing is typed
   * anywhere, and `notePlanOutput` still reads the plan lines off the session's
   * own output for every session regardless of provider.
   */
  const running = runningProvider(provider, agent.running)
  const { readings, busy, notice, dismissNotice, wired, pick } = useSessionControls(
    sessionId,
    cwd,
    running,
    target,
  )
  /*
   * Every control's rows come from the catalogue, and **opening a menu types
   * nothing**.
   *
   * ## What this replaces
   *
   * Until 2026-08-19 the model menu called `discoverModels` on the way open,
   * which typed `/model` into the live session, read the picker the CLI drew and
   * pressed Esc. It was written as a considered trade — the list would be the
   * *account's* own, which a table in this repo can never guarantee — and the
   * cost was known and written down in that function: cancelling the picker
   * makes the CLI print `Kept model as …`, so every look left a line in the
   * conversation.
   *
   * Watching it, Asad:
   *
   *   > *"if I click on Opus, it will run a command just to view, just to view
   *   > it is running a command. I'm not even clicking on the next one which I
   *   > want to choose but just by drop down, as soon as drop down comes down it
   *   > runs the command automatically. At least when I click on something then
   *   > it should run."*
   *
   * His recording shows **five** `/model` blocks stacked in a working
   * conversation. That is not a tuning problem. A menu is a thing you open to
   * find out what is behind it, frequently by accident, and the one place this
   * app must never write is somebody's session — which is the rule the rest of
   * this file is built on: *"a control here is honest exactly when a person
   * could have done the same thing at the keyboard"*, and nobody types a slash
   * command in order to look at a list.
   *
   * ## What the catalogue costs, argued rather than waved at
   *
   * It can be stale. `shared/model-catalog.ts` holds `FALLBACK_MODELS`, captured
   * verbatim off `claude 2.1.234` on this machine, plus `PREVIOUS_MODELS` — the
   * names the picker hides and `/model` still accepts. A model released after
   * this build is not in either, and an account restricted by its organisation
   * may be offered a row it cannot actually use.
   *
   * Both of those fail *safely*, and that is the whole of the trade. A missing
   * row costs one `/model <name>` typed by hand, in a terminal that is right
   * there. A row the account is barred from is answered by the CLI in its own
   * words — `Mythos 5 isn't available for your account yet`, captured live — and
   * `applyControl` shows that verbatim on the notice strip below this bar. The
   * live read's failure mode is not comparable: it writes into somebody's work
   * to render a menu, whether or not they choose anything, every single time.
   *
   * The keystroke has not been moved earlier or made cheaper. It happens when a
   * value is picked and at no other moment, which is what he asked for in the
   * last sentence of the quotation.
   *
   * ## What is left of the old path
   *
   * Nothing on this side. `discoverAgentModels` still exists in the main process
   * and on the bridge; this cluster simply never calls it, and neither does
   * anything else in the renderer. Removing the far end is a change to
   * `src/main/agent-controls.ts` and its own tests, which is not this file's to
   * make — but it is dead from here, and this paragraph is the note that says so
   * for whoever finds it.
   */
  const optionsForRow = useCallback(
    (id: ControlId): ControlOption[] =>
      id === 'model' ? [...modelOptions(), ...previousModelOptions()] : optionsFor(id),
    [],
  )
  /*
   * What connectors this session's directory actually resolves to.
   *
   * Asked here rather than inside the chip because the answer decides whether
   * there *is* a chip, and a component that decides its own existence cannot be
   * the one that fetches the fact — it would have to render once to find out.
   * See `use-connectors.ts`.
   */
  const connectors = useConnectors(target === undefined ? cwd : null)
  /*
   * And never for a session on another computer, which is not a layout decision.
   *
   * `listMcpServers` resolves the connectors of a folder **on this machine** —
   * its `.mcp.json`, this app's own registry, this user's globals. A session on
   * a paired desktop or on a server has its own, over there, and nothing on
   * either wire carries them; a chip fed from this machine's list would name
   * servers that session cannot reach and open a view that manages the wrong
   * computer's. So the chip is absent and the bar says where they really live —
   * see `RemoteControlsNote`, which is now down to exactly the two things that
   * genuinely cannot travel.
   *
   * `null` rather than `cwd` on the hook above for the same reason and one more:
   * a remote path that happens to exist on this machine too would otherwise
   * resolve *this* machine's project connectors under somebody else's session.
   */
  const hasConnectors = target === undefined && connectors.loaded && connectors.rows.length > 0
  /*
   * What the row needs changes with what it is saying, and nothing about that
   * resizes the bar — so the widths that decide the fold are re-read whenever
   * one of these labels does. `busy` is in here because "Working…" is drawn in
   * place of a value and is a different width from every value it replaces, and
   * the connector count because a chip appearing is a chip's worth of width the
   * row did not have a moment ago.
   */
  const signature = [
    running ?? '',
    busy ?? '',
    readings?.model.label ?? '',
    readings?.effort.label ?? '',
    readings?.fast.label ?? '',
    hasConnectors ? 'mcp' : '',
  ].join('|')
  const { layout, clamp, attach } = useClusterFit(host, signature)
  const folded = layout === 'folded'
  /**
   * How much of itself the folded chip may say, from the same measured room.
   *
   * See {@link summaryDetail}, where the three states and the two thresholds are
   * argued and the measurements are written down.
   */
  const detail = summaryDetail(clamp)
  /**
   * How much of itself the usage reading can afford to draw here.
   *
   * ## Why the reading does not simply follow the fold
   *
   * It used to. `UsageBar` took this cluster's `folded` flag and gave up its
   * renewal clause whenever the *controls* collapsed — and the real app is where
   * that showed up as wrong. On a session called "Update Claude Code terminal to
   * new…" the controls folded at a **1440pt window**, because `control-room.ts`
   * protects the session name's share of the bar before it gives anything to the
   * chips; and the reading dutifully dropped `resets 4:40am` with 645 pixels of
   * room going spare.
   *
   * ## Two tiers now, where there were three
   *
   * The middle one existed to drop the renewal clause and narrow the meters,
   * and both of those are inside the dropdown since 2026-08-19. What is left on
   * the bar is a context figure and a plan icon, and neither of them may be
   * given up: a *reading* that is hidden is indistinguishable from one that was
   * never reported, and a control that is hidden cannot be reached at all. So
   * the narrow tier folds the icon into the figure rather than dropping either —
   * the figure takes the press — and {@link TIGHT_BELOW_PX} holds the one
   * measured threshold that is left.
   *
   * Read off `clamp` rather than off a window width, for the same reason the
   * fold is: a split pane can be narrow inside a wide window, and it is the bar
   * this cluster is actually in that decides. `null` — nothing measured yet —
   * is `full`, because the unclamped row is what the first paint should draw
   * and what this component's own tests render.
   */
  const fit: UsageFit = clamp === null || clamp >= TIGHT_BELOW_PX ? 'full' : 'tight'

  const shut = useCallback(() => setOpen(false), [])
  // The window's one-menu-at-a-time rule. This panel and the pickers beside it
  // share a root, so without it a chip pressed while the panel is open would
  // open its own menu across the panel — see `one-menu.ts`, which exists for
  // exactly that overlap in the composer.
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

  /*
   * A shell is not an agent, and the whole cluster withdraws for one.
   *
   * Not disabled-with-a-reason, which is what every other unusable state here
   * gets, because there is no missing capability to explain: the pty in front
   * of you is `/bin/zsh -l` and it has no model to set. A row of four greyed
   * chips over a shell would be teaching the reader that this app *could* set a
   * model on their shell if only something were different. The same judgement
   * `AgentControls` makes, and `finish.test.ts` pins there.
   *
   * ## `running`, not `provider`, and that one word is the reported bug
   *
   * The record says `shell` for the whole life of a session started as one,
   * including every minute an agent is running inside it. Read straight, this
   * line took the entire control surface off the bar of exactly the sessions
   * Asad works in — see the note beside `useAgentPresence` above for the frames
   * it came from. `runningProvider` withdraws that answer the moment the screen
   * contradicts it, so what withdraws the cluster now is a shell that is *still
   * a shell*, which is what this paragraph always claimed to be about.
   *
   * ## Three answers, and why two of them draw nothing
   *
   * `running` is `'shell'` in two situations and both are right to be empty:
   * the screen was read and there is no agent, and nothing has been read yet.
   * The second is the interesting one. Guessing "agent" while unknown would put
   * live model and effort chips on a plain `/bin/zsh -l` for the few hundred
   * milliseconds before the first reading lands — the `Model  Opus 5` over a
   * shell that this paragraph opens with, back again as a flicker. Drawing
   * nothing and then appearing is the honest order, and it is the same order
   * the account chip beside it already follows for the same reason.
   *
   * ## And when the agent exits
   *
   * It goes back to nothing. Two different exits reach that answer by two
   * routes and neither is a special case here: `/exit` leaves the shell alive
   * and clears Claude Code's screen, so the next reading finds no marker and
   * `settle` — which spends one extra reading before believing a disappearance
   * — flips `running` back to `'shell'`; and a dead pty is settled by the
   * record, because `presenceFromSession` looks at `exited` before it looks at
   * anything else. That second route is the whole reason `exited` is a required
   * prop: a killed CLI leaves its banner on the last frame of the screen, so
   * without the record this line would go on drawing live chips over a corpse.
   */
  if (running === 'shell') return null

  const foreignNote = foreignAgentNote(running)
  /*
   * Why nothing can be changed at this instant, for one control.
   *
   * Ordered outermost first, because the reasons nest: a build with no bridge
   * cannot type anything at any CLI; a CLI this build has not been shown cannot
   * be typed at whatever the session is doing; a control the account is barred
   * from stays barred while the prompt is free; and the keyboard gate is the
   * one that comes and goes.
   *
   * Every sentence is quoted from somewhere it is already written — the
   * account's refusal from whatever the CLI itself printed, the keyboard gate
   * from `refuseToType` in `src/main/agent-controls.ts` — so the reason shown
   * before a click and the reason returned after one cannot drift. The one
   * exception is `foreignAgentNote`, which used to be quoted out of
   * `catalog.ts` and is now written above: nothing at the far end ever returns
   * it, because a session it applies to is one this app never types into at
   * all, so there is no second copy for it to drift from. See its own note for
   * why the wording had to leave the catalogue.
   */
  const blockedFor = (control: ControlId): string | null => {
    if (!wired) return 'Model, effort and fast mode are not wired into this build.'
    if (foreignNote !== null) return foreignNote
    const barred = readings?.[control].unavailableReason
    if (barred) return barred
    if (readings !== null && !readings.gate.canType) {
      return readings.gate.reason ?? 'This session cannot be typed into right now, so nothing was sent.'
    }
    return null
  }

  /**
   * The control drawn at the end of another control's menu, or nothing.
   *
   * Every prop is the same expression the host's own chip uses, read against the
   * *nested* id — `busy === inner`, not `busy === outer`. That is the whole of
   * what this function has to get right, and getting it wrong is silent: a
   * nested control wired to its host's `busy` would grey itself out whenever a
   * model was being applied, and a nested control wired to its host's `blocked`
   * would refuse whenever the account could not have the model, with a sentence
   * about models printed under a switch that works perfectly well. Two controls,
   * two answers, one menu.
   *
   * Which control goes where is {@link NESTED_CONTROLS} and not a name written
   * out here, so the row and the map cannot come to disagree.
   */
  const nestedIn = (outer: ControlId): ReactNode => {
    const inner = NESTED_CONTROLS[outer]
    if (inner === undefined) return null
    return (
      <ControlToggleItem
        control={inner}
        reading={readings?.[inner]}
        options={optionsForRow(inner)}
        reach={reachOf(inner)}
        busy={busy === inner}
        disabled={busy !== null && busy !== inner}
        blocked={blockedFor(inner)}
        onPick={(value) => pick(inner, value)}
      />
    )
  }

  const connectorsBlocked =
    onOpenConnectors === null
      ? 'The MCP servers view is not installed in this build, so there is nowhere for this to open.'
      : null

  const modelValue = displayValue(readings?.model, 'model')
  /*
   * The same shortening the model chip does, for the summary that replaces it
   * when the bar folds. `Opus 5 with 1M context` has even less room here than on
   * the chip — this box shares fourteen characters with the effort value — and a
   * summary is the one place an ellipsis is least readable, because there is no
   * menu under it printing the full name. The `title` and the accessible name
   * below still carry the value as it was read.
   */
  const modelShown = shortModelLabel(modelValue)
  const effortValue = displayValue(readings?.effort, 'effort')

  /**
   * What the session said about the last change.
   *
   * A bar is one row tall and these are the CLI's own sentences — "Model is now
   * Sonnet 5 — saved as your default for new sessions", or "Fast mode requires
   * usage credits · /usage-credits to turn them on" — so it hangs underneath on
   * the app's glass rather than squeezing into the row. A confirmation clears
   * itself after a few seconds; a failure stays until it is dismissed, because
   * an error that tidies itself away is an error nobody read.
   */
  const noticeNode =
    notice === null ? null : (
      <p className={notice.ok ? 'sc-notice' : 'sc-notice sc-notice-bad'} role="status">
        <span className="sc-notice-text">{notice.text}</span>
        <button type="button" className="sc-notice-close" aria-label="Dismiss" onClick={dismissNotice}>
          <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden="true">
            <path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />
          </svg>
        </button>
      </p>
    )

  /** The same notice, drawn inside the folded panel while that panel is open. */
  const sheetNotice = folded && open ? noticeNode : null

  return (
    <div
      className="session-controls"
      ref={attach}
      data-folded={folded || undefined}
      /* The reading's tier, published so the *controls* can react to it too —
         `.sc-summary` gives up five pixels of its floor at `tight`, which is
         what stops the reading beside it losing a percent sign. See the note
         beside that rule. */
      data-fit={fit}
      /* And how much of itself the folded chip is saying, published for the same
         reason: `.sc-summary` needs a different floor in each of the three
         states, and CSS has no way to ask this question for itself. */
      data-detail={detail}
      /*
       * The last line of defence, and the only one that is unconditional.
       *
       * The fold above decides what *should* fit. This says what may be drawn
       * whatever the answer was — the room left on this bar before a control
       * that never gives way is covered. A guest pane dragged down to 124px has
       * about fifty pixels here, and fifty pixels is what the cluster gets: the
       * chips clip themselves rather than paint over the close button, because
       * closing a pane is the one thing a pane's bar must always be able to do.
       * Without it the folded chip kept its natural width at any pane size and
       * hung 69px past the end of the bar, measured.
       */
      style={clamp === null ? undefined : ({ '--sc-room': `${clamp}px` } as CSSProperties)}
    >
      {/*
        The reading, first, and outside the fold.

        First because this cluster sits at the end of a bar whose other end
        carries the account, so the first chip in the row is the one nearest the
        thing it is a reading of — *"where we show the account, next to it we
        show a bar"* — and because it is the only element here that is a fact
        rather than a switch.

        Outside the fold because folding it would hide it, and a hidden reading
        and an absent one look the same. Instead it is told how much room there
        is and gives things up in order: `folded` costs it the renewal clause,
        and `tight` — the state at the narrowest window this app permits —
        costs it the window name, both meters and the caret, leaving the two
        percentages, which are the reading. See `UsageBar.css`.
      */}
      {/*
        And it is handed the same `target` the pickers above it are routed by,
        for the opposite purpose.

        The pickers take it to send the question to the machine the session is
        on. This takes it to stop asking a question of the wrong one: both
        figures on that bar are read *here* — the plan limits from the login
        signed in on this computer, the context window from a transcript on this
        disk — so a bar left unaware of the target reported this Mac's account
        under a session running on his PC and a blank where a context figure
        should be, drawn identically to a local one. `usage-reach.ts` holds what
        it does with it, and what a version that could genuinely ask the far
        machine would cost.
      */}
      <UsageBar sessionId={sessionId} provider={running} fit={fit} target={target} />

      {folded ? (
        <>
          {/*
            One chip, and what is on it is the two values.

            The failure to avoid is documented at length in `catalog.ts`: a
            button labelled "More" hid two controls and they were reported as
            *deleted*, because nothing on screen named them. A first attempt
            here showed the model's value alone, which is worse than "More" and
            not better — on a session whose model has not been read yet the bar
            simply said `Unknown ⌄`, which names nothing and reads as broken.
            The second attempt named the model and dropped the effort, and that
            is the same mistake one control further along: this app reads
            `Effort Ultracode` off a real settings file, and a bar that has room
            to say so and does not is hiding a fact it knows.

            So both values are here, in the order the expanded row wears them —
            and, since 2026-08-17, without their names. Asad, looking at the
            expanded row: *"no need to show the other things like only show Opus
            5. If they drop down, they know that this is a model. So no need to
            tell that Model Opus 5 — just Opus 5 with drop down is good enough.
            Also effort, no need to tell effort."* That is a judgement about the
            *reader*, and it is the same one on this chip: `Opus 5 · Ultracode ⌄`
            is two values and a caret, and a person who presses it is shown both
            names a tenth of a second later. What the "More" button lacked was
            not names on the chip, it was any way at all to find out — and that
            is covered here twice over, by the hover label below, which names
            every control behind the fold, and by the panel it opens.

            What folds away entirely is fast mode — which by its own account in
            `catalog.ts` spends most of its life with nothing to report — and
            connectors, which is a list with no value to put on a chip.

            Below the width where even that fits, the chip clips from its
            trailing edge under a short fade rather than shrinking its words to
            mush: the model survives longest because it is first, and the whole
            of it is in the hover label at every width. That is a deliberate
            choice about which half of the truth to keep when there is only room
            for half.
          */}
          <button
            type="button"
            className="cc-chip sc-summary"
            aria-haspopup="dialog"
            aria-expanded={open}
            aria-label={`Session controls: ${summaryLabel(modelValue, effortValue, hasConnectors)}`}
            title={summaryLabel(modelValue, effortValue, hasConnectors)}
            /* Opening this asks the session nothing. It used to — the sheet
               draws every control at once, so it called the same discovery the
               model menu did — and nothing is typed here now for the reason set
               out beside `optionsForRow`: a person opening a panel to look at it
               is not a person asking for a slash command to be run in their
               conversation. */
            onClick={() => setOpen((was) => !was)}
          >
            {/*
              What the chip says, in the three sizes it comes in.

              `glyph` is the state that used to be a fade over nothing. At the
              app's own minimum window width this control has twenty-five pixels
              — measured, and floored there by `MIN_CLUSTER_PX` — and it spent
              them on a mask that painted a hundred and six pixels of label
              completely transparent. So at that width it stops being a label:
              it is a toolbar button with the sliders mark on it, which is what
              every Mac app does with a control it cannot spell out, and it says
              the whole of its business in the hover label and to a screen
              reader exactly as before. An icon that was chosen is honest; a word
              that was erased is not.

              `model` is the middle, and it is his own sentence about which half
              to keep: *"no need to show the other things like only show Opus 5.
              If they drop down, they know that this is a model."* One value
              whole beats two values half — and the effort is not lost, it is one
              press and one hover away, both of which name it.

              The names still appear when a value is `Unknown`, which is the same
              rule the open row's chips follow and for the same reason: `Opus 5`
              says what it is and `Unknown` says nothing, so the label it made
              redundant stops being redundant the moment the value goes. See the
              long note beside `.ac-picker:not(.sc-connectors) .ac-name` in the
              stylesheet — expressed there in CSS because those chips come from a
              shared component, and here in markup because this one does not.
            */}
            {detail === 'glyph' ? (
              <svg
                className="sc-summary-glyph"
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.8"
                strokeLinecap="round"
                aria-hidden="true"
              >
                <path d="M4 8h4M12 8h8M4 16h10M18 16h2" />
                <circle cx="10" cy="8" r="2" />
                <circle cx="16" cy="16" r="2" />
              </svg>
            ) : (
              <span className="sc-summary-text">
                {readings?.model.label ? null : <span className="ac-name">{controlName('model')}</span>}
                <span className={readings?.model.label ? 'ac-value' : 'ac-value ac-value-unknown'}>{modelShown}</span>
                {detail === 'both' ? (
                  <>
                    <span className="sc-summary-sep" aria-hidden="true" />
                    {readings?.effort.label ? null : <span className="ac-name">{controlName('effort')}</span>}
                    <span className={readings?.effort.label ? 'ac-value' : 'ac-value ac-value-unknown'}>
                      {effortValue}
                    </span>
                  </>
                ) : null}
              </span>
            )}
            <svg className="ac-caret" width="9" height="9" viewBox="0 0 12 12" aria-hidden="true">
              <path d={CARET} fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
            </svg>
          </button>

          {open ? (
            <div className="sc-sheet scroll-fade" role="dialog" aria-label="Session controls">
              {/* With the panel up, the answer belongs *in* it. Both hang off
                  the same chip, so a bubble floating below the bar lands on the
                  panel's own first section — seen on screen, covering the word
                  "Model" and half its description. Inside, it reads as what it
                  is: the reply to the option you just pressed, above the
                  options you pressed it in. */}
              {sheetNotice}
              {CHROME_CONTROLS.map((id) => (
                <ControlSection
                  key={id}
                  control={id}
                  reading={readings?.[id]}
                  options={optionsForRow(id)}
                  reach={reachOf(id)}
                  busy={busy === id}
                  disabled={busy !== null && busy !== id}
                  blocked={blockedFor(id)}
                  /* Same test as the open row above, for the same reason: a
                     control with two states is a switch in both places, and the
                     panel must not disagree with the bar about what shape a
                     control is. */
                  toggle={optionsForRow(id).length === 2}
                  onPick={(value) => pick(id, value)}
                />
              ))}
              {/* The same rule as on the open row: a section for connectors
                  only when this session's directory resolves to some. An empty
                  one used to be a heading, a blurb and a button that opened a
                  view with nothing in it — three lines of a 340px panel spent
                  on an absence. */}
              {hasConnectors ? (
                <section className="ac-section">
                  <h4 className="ac-section-name">Connectors</h4>
                  {/* The heading, and then the control. The sentence that used
                      to sit between them was the MCP view's blurb, and those are
                      deleted app-wide this round — see `shell/panels.ts`. */}
                  <div className="sc-sheet-actions">
                    <ConnectorsPicker
                      rows={connectors.rows}
                      onOpen={onOpenConnectors}
                      blocked={connectorsBlocked}
                    />
                  </div>
                </section>
              ) : null}
              <p className="ac-sheet-foot">
                Every change here is typed into this session, exactly as you would type it.
              </p>
            </div>
          ) : null}
        </>
      ) : (
        <>
          {/*
            One chip per control that has one, and fast mode no longer does.

            The row used to branch here on `optionsForRow(id).length === 2` and
            draw a `ControlToggle` chip for the two-state control. That branch is
            gone from the *bar* — *"move fast mode toggle inside the models
            dropdown at the end"* — and it is not gone from the app: the panel
            below still makes the same test, because a folded panel has room for
            a section per control and nests nothing. The shape test survives
            where a shape is still being chosen.

            Every prop is spelled out rather than gathered into an object and
            spread. A spread would be shorter and it is forbidden here for a
            reason this repository has already paid for: `renderer/wiring.test.ts`
            watches this exact seam by reading the opening tag, and a spread is
            invisible to it — its own comment says so twice. That guard exists
            because `ControlPicker` has shipped mounted with props missing, and
            `reading` in particular is the prop that makes a picker a picker
            rather than a label.
          */}
          {ROW_CONTROLS.map((id) => (
            <ControlPicker
              key={id}
              control={id}
              name={controlName(id)}
              reading={readings?.[id]}
              options={optionsForRow(id)}
              busy={busy === id}
              disabled={busy !== null && busy !== id}
              blocked={blockedFor(id)}
              nested={nestedIn(id)}
              onPick={(value) => pick(id, value)}
            />
          ))}
          {/* Only when there are some. *"A dropdown only when connectors exist.
              Hide it when empty."* — and `loaded` is why nothing flickers in
              and out while the answer is on its way. */}
          {hasConnectors ? (
            <ConnectorsPicker
              rows={connectors.rows}
              onOpen={onOpenConnectors}
              blocked={connectorsBlocked}
            />
          ) : null}
        </>
      )}

      {/* And with the panel shut, it hangs below the bar — see `noticeNode`. */}
      {sheetNotice === null ? noticeNode : null}
    </div>
  )
}
