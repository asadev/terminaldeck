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
  optionsFor,
  reachOf,
  unsupportedProviderNote,
  type ControlId,
} from '../chat/controls/catalog'
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
import { UsageBar } from './UsageBar'
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
 * **Permission mode.** It was not asked for, it is the one control with an
 * in-terminal gesture already (shift+tab, in the very terminal this bar sits
 * over), and it is the most expensive thing in the window to widen: five
 * options, a value that is often unknown, and a name long enough to cost
 * another chip's worth of a narrow bar. It keeps its chip in the composer.
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
   * What is running in the session.
   *
   * `shell` withdraws the whole cluster: a `/bin/zsh -l` has no model, no
   * effort and no fast mode, and the reader behind these values falls back to
   * Claude Code's own settings file when it cannot parse a screen — which is
   * how a plain shell once came to report `Model  Opus 5`. `finish.test.ts`
   * pins that behaviour for the composer's copy and it is the same fact here.
   *
   * `codex` and `gemini` do **not** withdraw it. They get the chips, drawn back
   * and carrying the sentence explaining that this build has not been shown how
   * those CLIs change a model at runtime — because those sessions genuinely have
   * a model, and a gap where a control should be says nothing about why.
   */
  provider?: ProviderId
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
 */
const CHROME_CONTROLS: readonly ControlId[] = ['model', 'effort', 'fast']

/**
 * What to believe about the row's own width until it has been measured once.
 *
 * Both figures are read off the running app — the full row at a 1440pt window
 * is Model 118, Effort 118, Fast mode 159, Connectors 77 and the usage chip,
 * plus the gaps; the folded row is the usage chip and one summary chip. They
 * are a starting point and nothing more: `naturalWidth` replaces each with the
 * real thing on the first paint that draws it, because the true width moves
 * with its own contents. `Opus 5` and `Opus 5 (1M context)` are not the same
 * chip, and a constant that pretends otherwise is a constant that was right on
 * the day it was written.
 *
 * This is the whole of what remains of `FOLD_BELOW_PX`, the single 900px
 * threshold this replaced. That number compared the wrong box — see
 * `control-room.ts`, which has the full account — and one number could never
 * have described both a 1176px window toolbar carrying a mode switch and a
 * 124px guest-pane bar carrying a close button.
 */
const FIRST_GUESS: LayoutNeeds = { full: 615, folded: 357 }

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
  /** Whether the folded chip's words are actually running past its own edge. */
  clipped: boolean
  attach: (node: HTMLDivElement | null) => void
} {
  const [layout, setLayout] = useState<ClusterLayout>('full')
  const [clamp, setClamp] = useState<number | null>(null)
  const [clipped, setClipped] = useState(false)
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
    // Whether the fade is earned. CSS cannot ask a box if it is overflowing, so
    // this is asked here and answered with an attribute — see
    // `.sc-summary[data-clipped]`.
    const words = cluster.querySelector('.sc-summary-text')
    setClipped(words !== null && words.scrollWidth > words.clientWidth + 1)
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

  return { layout, clamp, clipped, attach }
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
 * It names the four controls behind the chip and then states the two values
 * that are on it, so nothing on the bar is a value without a name and nothing
 * behind the fold is a control without a mention. Both readings are quoted
 * whole — the chip itself truncates a long model name to fourteen characters,
 * and this is where the rest of it lives.
 *
 * A function rather than a template in the JSX so that a test can hold it to
 * that, without a DOM and without grepping the file: the failure it guards is a
 * label that stops naming something the chip is still hiding.
 */
export function summaryLabel(modelValue: string, effortValue: string): string {
  return `${contentsSentence(true)} — model ${modelValue}, effort ${effortValue}`
}

const CARET = 'M2.5 4.5 6 8l3.5-3.5'

/**
 * The connectors chip.
 *
 * It is a door rather than a picker: this app already has an MCP surface — the
 * MCP servers view, with its own add form, its own inspector and its own
 * account of what each server exposes — and the thing missing was a way to
 * reach it from the session you are running. So this opens that view. Building
 * a second list of servers in a popover would be a second MCP system, drifting
 * from the first from the day it shipped.
 *
 * The label on it is the view's own, and the sentence under it is the view's own
 * blurb, both read from `panels.ts`. That is the same reason the Options button
 * in the composer builds its label from `MENU_CONTROLS`: a hand-typed name
 * outlives the thing it names.
 */
function ConnectorsChip({ onOpen, blocked }: { onOpen: (() => void) | null; blocked: string | null }) {
  const spec = panelSpec('mcp')
  return (
    <button
      type="button"
      className="cc-chip sc-connectors"
      aria-disabled={blocked !== null ? true : undefined}
      data-blocked={blocked !== null ? '' : undefined}
      title={blocked ?? `Connectors — ${spec.blurb}`}
      onClick={() => {
        if (blocked === null) onOpen?.()
      }}
    >
      <span className="ac-name">Connectors</span>
    </button>
  )
}

export function SessionControls({ sessionId, cwd, provider, onOpenConnectors }: SessionControlsProps) {
  const host = useRef<HTMLDivElement>(null)
  const [open, setOpen] = useState(false)
  const { readings, busy, notice, dismissNotice, wired, pick } = useSessionControls(sessionId, cwd, provider)
  /*
   * What the row needs changes with what it is saying, and nothing about that
   * resizes the bar — so the widths that decide the fold are re-read whenever
   * one of these labels does. `busy` is in here because "Working…" is drawn in
   * place of a value and is a different width from every value it replaces.
   */
  const signature = [
    provider ?? '',
    busy ?? '',
    readings?.model.label ?? '',
    readings?.effort.label ?? '',
    readings?.fast.label ?? '',
  ].join('|')
  const { layout, clamp, clipped, attach } = useClusterFit(host, signature)
  const folded = layout === 'folded'

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
   */
  if (provider === 'shell') return null

  const foreignNote = unsupportedProviderNote(provider)
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
        and an absent one look the same. It is handed `folded` and gives up its
        renewal clause instead; see `UsageBar.css`.
      */}
      <UsageBar sessionId={sessionId} provider={provider} folded={folded} />

      {folded ? (
        <>
          {/*
            One chip, and what is on it is the two values, each under its own
            name.

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

            So both are here, named and valued, in the order the expanded row
            wears them. What folds away is fast mode — which by its own account
            in `catalog.ts` spends most of its life with nothing to report — and
            connectors, which is a door with no value to hide. Both are named in
            the hover label, built from the cluster's contents rather than typed
            out, and both are a titled section in the panel this opens.

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
            data-clipped={clipped || undefined}
            aria-haspopup="dialog"
            aria-expanded={open}
            aria-label={`Session controls: ${summaryLabel(modelValue, effortValue)}`}
            title={summaryLabel(modelValue, effortValue)}
            onClick={() => setOpen((was) => !was)}
          >
            <span className="sc-summary-text">
              <span className="ac-name">{controlName('model')}</span>
              <span className={readings?.model.label ? 'ac-value' : 'ac-value ac-value-unknown'}>{modelValue}</span>
              <span className="sc-summary-sep" aria-hidden="true" />
              <span className="ac-name">{controlName('effort')}</span>
              <span className={readings?.effort.label ? 'ac-value' : 'ac-value ac-value-unknown'}>{effortValue}</span>
            </span>
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
                  options={optionsFor(id)}
                  reach={reachOf(id)}
                  busy={busy === id}
                  disabled={busy !== null && busy !== id}
                  blocked={blockedFor(id)}
                  onPick={(value) => pick(id, value)}
                />
              ))}
              <section className="ac-section">
                <h4 className="ac-section-name">Connectors</h4>
                <p className="ac-section-desc">{panelSpec('mcp').blurb}</p>
                <div className="sc-sheet-actions">
                  <ConnectorsChip onOpen={onOpenConnectors} blocked={connectorsBlocked} />
                </div>
              </section>
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
              options={optionsFor(id)}
              reach={reachOf(id)}
              busy={busy === id}
              disabled={busy !== null && busy !== id}
              blocked={blockedFor(id)}
              onPick={(value) => pick(id, value)}
            />
          ))}
          <ConnectorsChip onOpen={onOpenConnectors} blocked={connectorsBlocked} />
        </>
      )}

      {/* And with the panel shut, it hangs below the bar — see `noticeNode`. */}
      {sheetNotice === null ? noticeNode : null}
    </div>
  )
}
