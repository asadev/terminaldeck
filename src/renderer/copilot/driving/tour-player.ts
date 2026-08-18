/**
 * Playing a tour: navigate, point, move on — at machine speed, and then answer.
 *
 * ## The inversion this file was rewritten for
 *
 * It used to stop at each place *for him to read*, held there for as long as
 * `estimate.ts` thought the text needed. Asad, 2026-08-17:
 *
 *   > *"Currently it stays for us to read. Let's not make it for us to read. It
 *   > will do it in a way that it is reading it in very fast mode — it is going
 *   > here and there, it is going to all of those sessions… and we can see which
 *   > words it is making focus… it is scanning everything very fast and we can
 *   > see like a machine is working, a proper feel of high-speed intelligence."*
 *
 * So there are two phases and the reading is at the **end**:
 *
 * 1. **The scan.** {@link SCAN_HOLD_MS} on each stop, whatever it says. Nothing
 *    here measures text and nothing waits for a person.
 * 2. **The answer.** The last stop takes the screen back to the copilot's own
 *    window, where the app's record renders as one structured response grouped
 *    by session. That is what gets read, once, at whatever pace suits.
 *
 * The reading-time model is not turned down to zero — it is deleted. `shared/scan.ts`
 * carries the argument for why a dial that no longer moves anything is worse
 * than no dial at all.
 *
 * ## The loop, in the order it happens
 *
 *  1. **Dim off.** A scrim sliding across the window while a pane is also
 *     scrolling is two motions competing, and it repaints the shadow's quad on
 *     every frame of the journey.
 *  2. **Navigate.** Bring the session to the front, put it in the pane the stop
 *     needs — terminal for a `screen` stop, conversation for a `message` one —
 *     and, for a terminal, scroll the buffer so the quote is on screen.
 *  3. **Point.** `setFocus` hands the overlay the target; the overlay resolves
 *     it, chases it while the layout settles, and reports what it managed.
 *  4. **Arrive.** On the first report that the box is drawn, the dim comes up
 *     and the hold starts. Travel is still not counted — at 260 ms a stop, a
 *     tab switch charged against the hold would eat most of it.
 *  5. **Hold, and go.** No estimate, no ring, no waiting on anybody.
 *
 * ## Arrival is not optional
 *
 * A stop that never resolves would leave the playhead in `travelling` for ever,
 * burning frames over a fleet of terminals each painting a canvas. So arrival is
 * guaranteed: {@link ARRIVE_GRACE_MS} after entering a stop the scan arrives
 * regardless, marks the stop **degraded**, and says why — *"this one is in vim;
 * here is the text"*. A scan that quietly stops boxing is worse than one that
 * says why.
 *
 * ## Two index spaces, and why there have to be two
 *
 * The record on disk is indexed by the **plan**: stop 0 is the first stop the
 * copilot wrote, for ever, whatever happens next. The playhead is indexed by
 * what is **currently playable**, because carrying on after a hold can find that
 * a session has closed and drop stops out of the middle. Collapsing the two
 * would mean either a record whose indices shuffle — so "stopped after 4 of 11"
 * names a different stop than it did an hour ago — or a playhead that has to
 * step over holes, which every selector in the reducer would need to learn.
 *
 * So there is a plan, fixed, and an {@link order} into it. `order[playhead]` is
 * the record index. Two arrays and one lookup, in one file.
 */

import { clearFocus, setFocus, setLit } from '../../driving/focus-controller'
import {
  createAnchor,
  scrollToFocus,
  type FocusFailure,
  type FocusTarget,
} from '../../driving/focus-target'
import type { FocusReport } from '../../driving/FocusOverlay'
import { isDriveControlTarget, isTransportKey } from './interruption'
import { attachInterruption, browserScanEngine, type ScanEngine } from './scan-engine'
import { navigator as driveNavigator } from './navigator'
import { focusOf, paneFor, type TourMessage, type TourRecord, type TourStop } from './tour'
import { isScanning, type ScanState } from '../../../shared/scan'

/* ------------------------------------------------------------- constants -- */

/**
 * How long a stop may spend failing to resolve before the scan arrives anyway.
 *
 * Long enough to cover a whole navigation: a tab switch, a pane mode change,
 * `TerminalView`'s `ResizeObserver` firing, xterm refitting, and the overlay's
 * own 380 ms chase window on top of that. Short enough that a stop which
 * genuinely cannot be boxed — a session in `vim`, a browser page, a quote that
 * has scrolled out of the buffer — does not read as the app having hung.
 *
 * Unchanged by the move to machine speed, and worth saying why: this is a
 * *failure* budget, not a pace. In the ordinary case the overlay resolves
 * synchronously inside its own effect, so arrival lands on the first frame and
 * this timer never fires. It only ever costs anything on a stop that was never
 * going to be boxable, and there the alternative is a scan that stalls.
 */
export const ARRIVE_GRACE_MS = 900

/**
 * A hold longer than this makes carrying on re-check *every* remaining stop
 * rather than only the next one.
 *
 * Five minutes. Under it, the stop being resumed onto is the only one worth
 * re-resolving; over it the fleet has moved on, and walking somebody into four
 * stops that are no longer there is worse than saying once that three of the
 * remaining seven have gone.
 */
export const RESUME_STALE_MS = 5 * 60_000

/** The attribute the driving panel wears, so its own clicks do not interrupt. */
export const PANEL_ATTR = 'data-drive-panel'

/* ----------------------------------------------------------------- shapes -- */

/** What the panel draws: everything the scan reducer does not already say. */
export interface TourView {
  record: TourRecord
  /** The stops still playable, in play order. Indexes match the playhead. */
  stops: readonly TourStop[]
  /**
   * `recordIndexes[playheadIndex]` is that stop's index in the record.
   *
   * Published rather than left implicit because the two diverge the first time a
   * recount drops a stop out of the middle, and everything the panel reads out
   * of the record — the session's title, whether it has been shown — is keyed
   * the record's way.
   */
  recordIndexes: readonly number[]
  scan: ScanState
  /** Set while the stop on screen is navigable but not boxable. */
  degraded: { index: number; why: FocusFailure } | null
  /** Stops this window dropped on carrying on, on top of the ones main dropped. */
  droppedHere: Array<{ title: string; why: FocusFailure }>
  ended: boolean
}

export type TourCommand = 'back' | 'toggle' | 'next' | 'stop'

export interface TourReporter {
  (message: {
    kind: 'started' | 'progress' | 'ended'
    tourId: string
    record: Partial<TourRecord>
  }): void
}

export interface PlayerDeps {
  /** Told what the window did, so the record on disk stays current. */
  report: TourReporter
  /**
   * The copilot's own session, so the scan can end where the answer is.
   *
   * *"Once it is all done it takes us back to its own chat box."* Null when the
   * copilot is not running in this window — the scan then simply stops where it
   * is, which is honest: there is no chat to go back to.
   */
  copilotSessionId?: string | null
  /** Injected for tests; a real frame-driven engine otherwise. */
  engine?: ScanEngine
  now?(): number
}

export interface RunningTour {
  view(): TourView
  subscribe(listener: () => void): () => void
  command(command: TourCommand): void
  /**
   * Go straight to a stop, by its index in {@link TourView.stops}.
   *
   * The manual override for "wait, what was that one", and the reason every row
   * in the trace is a button. It matters more at machine speed than it did at
   * reading speed: the trace fills faster than anybody can follow, so clicking
   * back into it is the primary way a person interacts with a scan at all.
   */
  jump(index: number): void
  /** The overlay's verdict on the current target. This is what makes it arrive. */
  reported(report: FocusReport): void
  /** End it and take everything off screen. Idempotent. */
  end(): void
}

/* ----------------------------------------------------------------- player -- */

export function playTour(message: TourMessage, deps: PlayerDeps): RunningTour {
  const now = deps.now ?? (() => Date.now())
  const engine = deps.engine ?? browserScanEngine()
  const listeners = new Set<() => void>()

  /** Fixed for the life of the scan. Indices here are the record's indices. */
  const plan: readonly TourStop[] = message.stops
  /** Which of them are still playable, in play order. See the header. */
  let order: number[] = plan.map((_, index) => index)

  let record: TourRecord = message.record
  let view: TourView = {
    record,
    stops: order.map((index) => plan[index]),
    recordIndexes: order,
    scan: engine.getState(),
    degraded: null,
    droppedHere: [],
    ended: false,
  }

  /** Playhead index the screen is currently pointed at, or -1 before the first. */
  let pointedAt = -1
  /** Non-null while a stop is still travelling. Cleared on arrival. */
  let graceTimer: ReturnType<typeof setTimeout> | null = null
  /** The last failure the overlay reported for the stop being entered. */
  let lastFailure: FocusFailure | null = null
  let heldAt: number | null = null
  let ended = false

  const recordIndex = (playIndex: number): number => order[playIndex] ?? -1
  const stopAt = (playIndex: number): TourStop | undefined => plan[recordIndex(playIndex)]

  const publish = (next: Partial<TourView> = {}): void => {
    view = {
      ...view,
      ...next,
      record,
      stops: order.map((index) => plan[index]),
      recordIndexes: order,
      scan: engine.peek(),
      ended,
    }
    for (const listener of listeners) listener()
  }

  /* ------------------------------------------------------------ the record -- */

  const noteShown = (playIndex: number, at: number): void => {
    const index = recordIndex(playIndex)
    record = {
      ...record,
      stops: record.stops.map((stop) =>
        stop.index === index && stop.shownAt === null ? { ...stop, shownAt: at } : stop,
      ),
    }
  }

  const noteLeft = (playIndex: number, failure: FocusFailure | null): void => {
    const index = recordIndex(playIndex)
    const shown = record.stops.find((entry) => entry.index === index)?.shownAt ?? null
    record = {
      ...record,
      stops: record.stops.map((stop) =>
        stop.index === index
          ? {
              ...stop,
              // Wall-clock from the moment the box was drawn. Kept even though
              // nothing paces against it any more: it is the only evidence that
              // the screen actually held this stop for the time it claims, which
              // is what makes the record an account rather than a restatement of
              // the plan.
              dwellMs: shown === null ? null : Math.max(0, now() - shown),
              degraded: failure !== null,
              degradedWhy: failure === null ? null : degradeSentence(failure),
            }
          : stop,
      ),
    }
    deps.report({ kind: 'progress', tourId: record.id, record })
  }

  /* ------------------------------------------------------------- movement -- */

  /**
   * Put the screen where this stop is, without waiting for it to get there.
   *
   * Navigation is fire-and-forget on purpose. Every call below is a React state
   * change that lands on the next render, and the overlay is already chasing —
   * so what decides "we have arrived" is the overlay's own report, not a promise
   * from any of these. That is also why a stop whose session is not in front
   * still works: the tab switch and the box resolving are two independent things
   * converging, rather than a sequence with a hand-off in the middle.
   */
  const travelTo = (stop: TourStop): void => {
    const nav = driveNavigator()
    const cwd = nav?.cwdOf(stop.sessionId) ?? null

    setLit(false)
    lastFailure = null

    if (nav !== null) {
      const pane = paneFor(stop)
      if (pane !== null) {
        /*
         * The pane first, then the tab.
         *
         * Both orders work and this one flickers less: setting the mode on a
         * session that is not in front changes nothing anybody can see, whereas
         * bringing it forward first shows one frame of the pane the person is
         * not being taken to.
         */
        nav.setSessionMode(stop.sessionId, pane)
        nav.selectTab(stop.sessionId)
      } else if (stop.kind === 'anchor' && stop.at === 'git-file') {
        // Source control is one of the ten project views and is keyed on the
        // folder, not the session — see `focus-target.ts` on why the git anchor
        // carries a `cwd`. The session still comes forward first, because the
        // panel draws the folder of whatever is in front.
        nav.selectTab(stop.sessionId)
        nav.showPanel('git')
      } else {
        // A usage strip lives under a session's chat, so the session is the
        // whole of the navigation.
        nav.selectTab(stop.sessionId)
      }
    }

    const target = focusOf(stop, cwd)
    if (target === null) {
      /*
       * The window does not know that anchor — the one failure this renderer's
       * mirror of the plan can produce, and the reason `tour.ts` returns null
       * rather than guessing. Point at the session's row instead, so at least
       * the right session is lit, and let the grace timer mark it degraded.
       */
      lastFailure = 'anchor-missing'
      setFocus({ kind: 'anchor', anchor: { at: 'session-row', sessionId: stop.sessionId } }, false)
      return
    }
    setFocus(target, false)
    scrollIfNeeded(target)
  }

  /**
   * Put a terminal's viewport where the quote is.
   *
   * Only terminals, and only when the region is not already visible —
   * `scrollToFocus` checks that itself, because scrolling a passage that is
   * already on screen moves the page for no reason.
   *
   * A chat bubble needs no equivalent here: `ChatView` watches the focus store
   * and scrolls its own scroller, because it is the only thing that can also
   * clear its stick-to-bottom flag — without which the next line of output on a
   * live session yanks the view back to the end.
   */
  const scrollIfNeeded = (target: FocusTarget): void => {
    if (target.kind !== 'terminal') return
    try {
      scrollToFocus(createAnchor(target))
    } catch (error) {
      // A terminal mounted but not laid out can throw out of the measurement.
      // That is a degraded stop, not a broken scan.
      console.error('[driving] could not scroll to the quote:', error)
    }
  }

  const enterStop = (playIndex: number): void => {
    const stop = stopAt(playIndex)
    if (stop === undefined) return
    pointedAt = playIndex
    if (graceTimer !== null) clearTimeout(graceTimer)
    travelTo(stop)
    graceTimer = setTimeout(() => {
      /*
       * Nothing resolved in time. Arrive anyway, degraded, with whatever the
       * overlay last said. The dim stays down, because a scrim with no hole in
       * it is the window dimmed for no reason at all.
       */
      graceTimer = null
      const why = lastFailure ?? 'anchor-missing'
      noteShown(playIndex, now())
      publish({ degraded: { index: playIndex, why } })
      engine.dispatch({ kind: 'arrive', at: performanceNow() })
    }, ARRIVE_GRACE_MS)
    publish({ degraded: null })
  }

  /* ---------------------------------------------------------- the overlay -- */

  const reported = (report: FocusReport): void => {
    if (ended) return
    if (report.drawn) {
      lastFailure = null
      if (graceTimer !== null) {
        clearTimeout(graceTimer)
        graceTimer = null
        setLit(true)
        noteShown(pointedAt, now())
        publish({ degraded: null })
        engine.dispatch({ kind: 'arrive', at: performanceNow() })
      }
      return
    }
    lastFailure = report.why ?? null
    if (graceTimer === null && view.degraded?.index === pointedAt) {
      // Already arrived degraded. Keep the sentence current if the reason
      // changed — a session leaving `vim` mid-stop is a real thing.
      publish({ degraded: { index: pointedAt, why: lastFailure ?? 'anchor-missing' } })
    }
  }

  /* -------------------------------------------------------------- the run -- */

  /**
   * Follow the playhead.
   *
   * The engine is the authority on *when*; this is what happens as a result.
   * Subscribing rather than driving it is what keeps every timing rule inside
   * the pure module where it can be tested against a fake clock.
   */
  const unsubscribe = engine.subscribe(() => {
    if (ended) return
    const state = engine.getState()

    if (state.status === 'finished') {
      finish()
      return
    }

    if (state.index !== pointedAt && isScanning(state)) {
      if (pointedAt >= 0) noteLeft(pointedAt, lastFailure)
      enterStop(state.index)
    }

    if (state.status === 'paused' && heldAt === null) heldAt = now()
    if (state.status !== 'paused' && heldAt !== null) heldAt = null

    publish()
  })

  /* --------------------------------------------------------- interruption -- */

  const watch = attachInterruption(engine, {
    window,
    document,
    now: () => performanceNow(),
    isOwnControl: (target) => isDriveControlTarget(target) || isPanelTarget(target),
    isCommandKey: isTransportKey,
    isHidden: () => document.visibilityState === 'hidden',
    // A collapsed selection is a focus change, not a person reading with a
    // finger on the page. Without this the panel taking focus stopped the scan
    // before it had drawn its first box — see `hasSelection` in
    // `interruption.ts` for the whole of it.
    hasSelection: () => (document.getSelection()?.toString() ?? '') !== '',
  })

  /**
   * The four keys the scan owns while it is playing.
   *
   * Capture phase and `stopImmediatePropagation`, which is the part worth
   * justifying: during a scan these four chords belong to the scan, and letting
   * them through would type a space into whichever pty happens to hold focus.
   * That is the closest thing there is to driving mode typing into a session,
   * and driving never types.
   *
   * Scoped as tightly as it can be: only while a scan is running, only these
   * four keys, and only with no modifier held, so every ⌘ chord in the app still
   * works. The frame the scan ends, the keys go back.
   */
  const onKey = (event: KeyboardEvent): void => {
    if (ended || !isScanning(engine.peek())) return
    if (event.metaKey || event.ctrlKey || event.altKey) return
    if (!isTransportKey(event.key)) return
    event.preventDefault()
    event.stopImmediatePropagation()
    switch (event.key) {
      case ' ':
        command('toggle')
        return
      case 'ArrowRight':
        command('next')
        return
      case 'ArrowLeft':
        command('back')
        return
      case 'Escape':
        command('stop')
    }
  }
  window.addEventListener('keydown', onKey, true)

  /* --------------------------------------------------------- the commands -- */

  const command = (name: TourCommand): void => {
    if (ended) return
    const at = performanceNow()
    switch (name) {
      case 'next':
        engine.dispatch({ kind: 'next', at, travel: true })
        return
      case 'back':
        engine.dispatch({ kind: 'back', at, travel: true })
        return
      case 'toggle':
        if (engine.peek().status === 'paused') resume()
        else engine.dispatch({ kind: 'pause', at, reason: 'asked' })
        return
      case 'stop':
        end()
    }
  }

  /**
   * Carry on — after re-checking that what was held on is still there.
   *
   * What this side can answer is whether the evidence is still on screen; the
   * reasons were checked in the main process against data this window does not
   * hold, and a second copy here is the exact duplication `importance.ts` exists
   * to prevent.
   */
  const resume = (): void => {
    const state = engine.peek()
    const stale = heldAt !== null && now() - heldAt > RESUME_STALE_MS
    const from = state.index
    const through = stale ? order.length - 1 : from

    const lost: number[] = []
    const dropped: TourView['droppedHere'] = []
    for (let index = from; index <= through; index += 1) {
      const failure = resolveFailure(stopAt(index))
      /*
       * `off-screen` and `alternate-buffer` are degradations, not losses: the
       * text is real and the session is there, so the stop still has something
       * to say and the panel says it. Only a stop whose evidence has actually
       * gone is dropped.
       */
      if (failure === 'quote-not-found' || failure === 'not-registered') {
        lost.push(index)
        const stop = stopAt(index)
        dropped.push({ title: stop?.note ?? 'a stop', why: failure })
      }
    }

    if (lost.length === 0) {
      /*
       * Redraw before starting the hold.
       *
       * Carrying on has to leave the person looking at the thing they stopped
       * on rather than at the thing after it, and the overlay may have been
       * moved or taken down while they were away — so the stop is entered again,
       * which re-navigates, re-points and re-arrives, and only then does the
       * engine's resume take effect.
       */
      enterStop(from)
      engine.dispatch({ kind: 'resume', at: performanceNow() })
      return
    }

    const gone = new Set(lost)
    const kept = order.filter((_, index) => !gone.has(index))
    if (kept.length === 0) {
      end()
      return
    }
    // Where the person lands: the same stop if it survived, otherwise the next
    // one that did. Counting the losses before `from` is what keeps that the
    // *same* stop rather than one shifted by however many vanished above it.
    const landing = Math.min(from - lost.filter((index) => index < from).length, kept.length - 1)
    order = kept
    publish({ droppedHere: [...view.droppedHere, ...dropped] })
    engine.dispatch({
      kind: 'recount',
      at: performanceNow(),
      count: order.length,
      index: Math.max(0, landing),
    })
    engine.dispatch({ kind: 'resume', at: performanceNow() })
    enterStop(Math.max(0, landing))
  }

  /* -------------------------------------------------------------- the end -- */

  /**
   * Take the screen back to the copilot, where the answer is.
   *
   * This is the second half of the feature and it is one line, because the
   * answer itself is not built here: the app's record is already on disk, and
   * `ScanAnswer` in the copilot's own window renders it grouped by session. All
   * this has to do is put that window in front, which is exactly what he asked
   * for — *"once it is all done it takes us back to its own chat box"* — and
   * nothing more, because a scan that also scrolled or selected something in the
   * chat would be one more unrequested movement at the moment he wanted movement
   * to stop.
   */
  const returnToCopilot = (): void => {
    const id = deps.copilotSessionId ?? null
    if (id === null) return
    driveNavigator()?.selectTab(id)
  }

  const finish = (): void => {
    if (ended) return
    ended = true
    if (graceTimer !== null) clearTimeout(graceTimer)
    graceTimer = null
    window.removeEventListener('keydown', onKey, true)
    watch.stop()
    unsubscribe()
    clearFocus()

    if (pointedAt >= 0) noteLeft(pointedAt, lastFailure)
    const shown = record.stops.filter((stop) => stop.shownAt !== null).length
    record = {
      ...record,
      endedAt: now(),
      /*
       * Only when it really was cut short.
       *
       * A scan that reached its last stop has nothing to confess, and "stopped
       * after 11 of 11" makes a completed scan look interrupted. Counted from
       * the stops actually shown rather than from the playhead, because the
       * playhead moves during a step back and the number being reported is "how
       * much did you see".
       */
      stoppedAfter: shown > 0 && shown < record.stops.length ? shown - 1 : null,
    }
    deps.report({ kind: 'ended', tourId: record.id, record })
    engine.destroy()
    returnToCopilot()
    publish()
  }

  const end = (): void => {
    if (ended) return
    engine.dispatch({ kind: 'stop', at: performanceNow() })
    finish()
  }

  /* ---------------------------------------------------------------- start -- */

  deps.report({ kind: 'started', tourId: record.id, record })
  engine.dispatch({ kind: 'play', at: performanceNow(), count: order.length })
  enterStop(0)

  return {
    view: () => view,
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    command,
    jump(index: number) {
      if (ended) return
      /*
       * A jump holds, and that is not the same decision `next` makes.
       *
       * Pressing → means "carry on from there" and the scan keeps running.
       * Clicking a row three stops back means "wait, show me that again", which
       * at machine speed is the only way anybody can look at a single stop —
       * answering it by scanning onward two hundred milliseconds later would
       * make the trace unclickable in practice.
       */
      engine.dispatch({ kind: 'jump', at: performanceNow(), index, travel: true })
      engine.dispatch({ kind: 'pause', at: performanceNow(), reason: 'stepped-back' })
    },
    reported,
    end,
  }
}

/* --------------------------------------------------------------- helpers -- */

function performanceNow(): number {
  return typeof performance === 'object' && typeof performance.now === 'function'
    ? performance.now()
    : Date.now()
}

/** Whether a stop's target resolves right now, and how it fails if it does not. */
function resolveFailure(stop: TourStop | undefined): FocusFailure | null {
  if (stop === undefined) return null
  const nav = driveNavigator()
  const target = focusOf(stop, nav?.cwdOf(stop.sessionId) ?? null)
  if (target === null) return 'anchor-missing'
  const resolved = createAnchor(target).measure()
  return resolved.ok ? null : resolved.why
}

function isPanelTarget(target: unknown): boolean {
  if (typeof target !== 'object' || target === null) return false
  const node = target as { closest?: (selector: string) => unknown }
  if (typeof node.closest !== 'function') return false
  return node.closest(`[${PANEL_ATTR}]`) !== null
}

/**
 * Why there is no box, in the person's terms.
 *
 * Every one of these is a state the design predicts and names, and each says
 * what is true rather than apologising. The `alternate-buffer` sentence is the
 * one the design document writes out itself: *"this one is in vim; here is the
 * text."*
 */
export function degradeSentence(why: FocusFailure): string {
  switch (why) {
    case 'not-registered':
      return 'That session is not open in this window, so there is nothing to box. The text is here.'
    case 'not-rendered':
      return 'That session is not on screen, so there is nothing to box. The text is here.'
    case 'alternate-buffer':
      return 'That session is in a full-screen program, which has no scrollback to box. The text is here.'
    case 'quote-not-found':
      return 'That text has scrolled out of what this window still holds. It is here.'
    case 'off-screen':
      return 'The text is outside the visible part of that pane.'
    case 'anchor-missing':
      return 'The thing this points at is not on screen right now.'
    case 'no-page':
      return 'There is no browser page open to point at.'
    default:
      return 'There is no box for this one.'
  }
}
