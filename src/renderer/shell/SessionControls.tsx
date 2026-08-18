import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type RefObject,
} from 'react'
import type { ProviderId } from '@shared/types'
import { ControlPicker } from '../chat/controls/ControlPicker'
import { ControlSection } from '../chat/controls/ControlSection'
import {
  controlName,
  displayValue,
  modelOptions,
  optionsFor,
  previousModelOptions,
  reachOf,
  unsupportedProviderNote,
  type ControlId,
  type ControlOption,
} from '../chat/controls/catalog'
import { runningProvider, useAgentPresence } from './agent-presence'
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
 * **Permission mode** used to be listed here, and is not any more — it joined
 * the cluster when the composer's control row was removed and it turned out to
 * be the one control that had no twin up here. The argument for leaving it out
 * is still worth reading and is now at `CHROME_CONTROLS`, next to the fact that
 * overruled it.
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
}

/**
 * The controls this cluster carries, in the order they are worn.
 *
 * Model first because it is the one that changes per task and the one he named
 * first. Fast mode last because it is the one that most often has nothing to
 * report — see `unreadLabel` in `catalog.ts`.
 *
 * ## Permission mode, which was deliberately not here and now is
 *
 * The note further up this file argues it out of this cluster, and every clause
 * of that argument still holds: it was not asked for, it is the one control with
 * a gesture in the terminal underneath this bar (shift+tab), and it is the most
 * expensive thing here to widen. It ended with "it keeps its chip in the
 * composer", and that is the clause that stopped being true:
 *
 *   > *"Options is showing the same options that we already have here… let's
 *   > not keep them here — remove them from the chat box side completely, only
 *   > keep the maybe add files or something."*
 *
 * The composer's row is gone. Every other control on it had a twin up here;
 * permission mode did not, so leaving it out would not have been "one home per
 * control", it would have been none — a working control deleted as a side
 * effect of removing duplicates of other controls. It is last but one so that
 * the fold sheds it before Model or Effort in a narrow bar, and
 * `chat/controls/one-home.test.ts` fails if it ever falls off this list without
 * gaining a home somewhere else.
 */
const CHROME_CONTROLS: readonly ControlId[] = ['model', 'effort', 'permission', 'fast']

/**
 * What to believe about the row's own width until it has been measured once.
 *
 * Both figures are read off the running app, and both were re-read on
 * 2026-08-18 after two changes moved them a long way. Dropping the names from
 * the chips — *"just Opus 5 with drop down is good enough"* — took roughly 40
 * pixels off each of the four; the usage reading gained about 40 by becoming
 * two lines and a wider grid. Measured with a live session reading `Opus 5`,
 * `Extra high`, `Bypass`, `Off` and two connectors: the full row is **551**
 * (of which the usage element is 178) and the folded row is **247** (usage
 * 107).
 *
 * They are a starting point and nothing more: `naturalWidth` replaces each with
 * the real thing on the first paint that draws it, because the true width moves
 * with its own contents. `Opus 5` and `Opus 5 (1M context)` are not the same
 * chip, and a constant that pretends otherwise is a constant that was right on
 * the day it was written. What a stale guess actually costs is one frame — an
 * unnecessary fold, or an unnecessary unfold, before the first measurement
 * lands — which is why these are worth keeping honest and not worth agonising
 * over.
 *
 * This is the whole of what remains of `FOLD_BELOW_PX`, the single 900px
 * threshold this replaced. That number compared the wrong box — see
 * `control-room.ts`, which has the full account — and one number could never
 * have described both a 1176px window toolbar carrying a mode switch and a
 * 124px guest-pane bar carrying a close button.
 */
const FIRST_GUESS: LayoutNeeds = { full: 551, folded: 247 }

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
 * lost controls behind an unnamed button once — see `MENU_CONTROLS` in
 * `catalog.ts` for the whole account.
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

  return (
    <div className="ac-picker sc-connectors" ref={root}>
      <button
        type="button"
        className="cc-chip"
        aria-haspopup="menu"
        aria-expanded={open}
        title={`Connectors — ${spec.blurb}`}
        onClick={() => setOpen((was) => !was)}
      >
        <span className="ac-name">Connectors</span>
        <svg className="ac-caret" width="9" height="9" viewBox="0 0 12 12" aria-hidden="true">
          <path d={CARET} fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        </svg>
      </button>

      {open ? (
        <div className="ac-menu sc-connectors-menu" role="group" aria-label="Connectors">
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
                  : spec.blurb
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

export function SessionControls({
  sessionId,
  cwd,
  provider,
  exited,
  onOpenConnectors,
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
  const agent = useAgentPresence(sessionId && provider ? { id: sessionId, provider, exited } : null)
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
   * `UsageBar` is handed it too, and there the cost of "not known" is worth
   * stating rather than leaving to be discovered. `auto-usage.ts` types
   * `/usage` into a session by itself and refuses to do that for anything but
   * `claude`, so a session whose CLI this app never saw does not get that
   * unasked fetch. The reading still arrives — `notePlanOutput` reads the plan
   * lines off the session's own output for every session regardless of provider
   * — it simply is not forced. That is the right way round: typing a slash
   * command into a terminal on the strength of a guess about which CLI is in it
   * is precisely the thing `undefined` exists to stop.
   */
  const running = runningProvider(provider, agent.running)
  const { readings, busy, notice, dismissNotice, wired, pick, models, discoverModels } = useSessionControls(
    sessionId,
    cwd,
    running,
  )
  /*
   * The model rows come from the session; every other control's come from the
   * catalogue.
   *
   * `modelOptions` folds the CLI's `Default` row into the model it points at and
   * labels every row with the model it resolves to — the two things Asad asked
   * for by name. `previousModelOptions` adds the ones the picker deliberately
   * hides but `/model` still accepts, which is where "Sonnet 4.6" and "Opus 4.x"
   * live. Before a session has been asked, `models` is null and the captured
   * picker stands in; the moment the menu is opened, `discoverModels` replaces
   * it with that session's own.
   */
  const optionsForRow = useCallback(
    (id: ControlId): ControlOption[] =>
      id === 'model' ? [...modelOptions(models ?? undefined), ...previousModelOptions()] : optionsFor(id),
    [models],
  )
  /*
   * What connectors this session's directory actually resolves to.
   *
   * Asked here rather than inside the chip because the answer decides whether
   * there *is* a chip, and a component that decides its own existence cannot be
   * the one that fetches the fact — it would have to render once to find out.
   * See `use-connectors.ts`.
   */
  const connectors = useConnectors(cwd)
  const hasConnectors = connectors.loaded && connectors.rows.length > 0
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
   * room going spare. That is one of the two things he asked for on the
   * five-hour line — *"it will show the percentage and it will show the time of
   * reset"* — withheld because a neighbour was short of space and this one was
   * not.
   *
   * ## The three tiers, and where each number comes from
   *
   * - **380 and up — `full`.** The renewal clause is either whole or absent;
   *   there is no third option, because *"resets 4:40am"* drawn as `res…` is an
   *   ellipsis where a fact should be. 380 is measured rather than reasoned:
   *   with the reading at its natural 194 and the folded controls chip at its
   *   natural 137, the clause came out whole at 365 of room and was cut at 325.
   *   Both of those naturals move with their contents — a longer reset string,
   *   a longer model name — and the ceilings are `18ch` for the clause and
   *   `14ch` for each value, which puts the worst case near 370. 380 covers it.
   *
   *   The first attempt at this number was 210, from the reading's natural width
   *   plus the controls chip's *floor*, and it was wrong for a reason worth
   *   keeping: flex does not hold the neighbour at its floor and hand the rest
   *   over, it shares the shortfall out proportionally. At 254 of room the
   *   reading got 158 of the 194 it wanted, and the tail column — the only part
   *   allowed to give — ate all 36 of the difference.
   * - **120 to 379 — `dense`.** The clause goes and the meters narrow to 26.
   *   A renewal time is a caption; the figures are not.
   * - **Under 120 — `tight`.** The figures alone. At the app's own minimum
   *   window width — 720, pinned in `src/main/index.ts` — this cluster gets 67
   *   pixels and flex handed the reading 22.9 of them, which drew the word `5h`
   *   and no number at all. Stripped, it measures 35, which with the controls
   *   chip's 30 and the 2-pixel gap is exactly the 67 there are.
   *
   * Read off `clamp` rather than off a window width, for the same reason the
   * fold is: a split pane can be narrow inside a wide window, and it is the bar
   * this cluster is actually in that decides. `null` — nothing measured yet —
   * is `full`, because the unclamped row is what the first paint should draw
   * and what this component's own tests render.
   */
  const fit: UsageFit = clamp === null || clamp >= 380 ? 'full' : clamp >= 120 ? 'dense' : 'tight'

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

  const foreignNote = unsupportedProviderNote(running)
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
   * provider note from `catalog.ts`, the account's refusal from whatever the
   * CLI itself printed, the keyboard gate from `refuseToType` in
   * `src/main/agent-controls.ts`. None of them is composed here, so the reason
   * shown before a click and the reason returned after one cannot drift.
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

  const connectorsBlocked =
    onOpenConnectors === null
      ? 'The MCP servers view is not installed in this build, so there is nowhere for this to open.'
      : null

  const modelValue = displayValue(readings?.model, 'model')
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
      <UsageBar sessionId={sessionId} provider={running} fit={fit} />

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
            onClick={() =>
              setOpen((was) => {
                // The folded sheet draws every control at once, so opening it
                // is the same moment the model menu's own button would be — see
                // `onOpen` on `ControlPicker` below.
                if (!was) discoverModels()
                return !was
              })
            }
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
                <span className={readings?.model.label ? 'ac-value' : 'ac-value ac-value-unknown'}>{modelValue}</span>
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
                  <p className="ac-section-desc">{panelSpec('mcp').blurb}</p>
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
          {CHROME_CONTROLS.map((id) => (
            <ControlPicker
              key={id}
              control={id}
              name={controlName(id)}
              reading={readings?.[id]}
              options={optionsForRow(id)}
              reach={reachOf(id)}
              busy={busy === id}
              disabled={busy !== null && busy !== id}
              blocked={blockedFor(id)}
              onPick={(value) => pick(id, value)}
              // Opening the model menu is what asks the session for its real
              // list. Every other control's options are facts about the CLI's
              // grammar and need no round trip.
              onOpen={id === 'model' ? discoverModels : undefined}
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
