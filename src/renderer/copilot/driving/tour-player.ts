/**
 * Playing a tour: navigate, point, wait for the reader, move on.
 *
 * This is the thing `DRIVING-MODE.md` §0 means by *"the app plays it"*. The
 * pacing engine underneath it was built first and separately — `estimate.ts`
 * says how long a stop takes, `pacer.ts` is the playhead, `interruption.ts`
 * watches the reader, `usePacer.ts` turns frames into ticks — and every one of
 * those is pure and testable against a fake clock. What was missing was the part
 * that knows what a session is, and this is it.
 *
 * ## The loop, in the order it happens
 *
 * For each stop:
 *
 *  1. **Dim off.** A scrim sliding across the window while a pane is also
 *     scrolling is two motions competing, and it repaints the shadow's quad on
 *     every frame of the journey. `setLit(false)` keeps the target and takes the
 *     scrim down; the overlay is still measuring underneath.
 *  2. **Navigate.** Bring the session to the front, put it in the pane the stop
 *     needs — terminal for a `screen` stop, conversation for a `message` one —
 *     and, for a terminal, scroll the buffer so the quote is on screen.
 *  3. **Point.** `setFocus` hands the overlay the target; the overlay resolves
 *     it, chases it while the layout settles, and reports what it managed.
 *  4. **Arrive.** On the first report that the box is drawn, the dim comes up
 *     and *only then* does the clock start. Counting travel as reading time is
 *     how a tour that looks correctly paced on paper feels rushed on screen.
 *  5. **Wait.** The pacing engine owns this entirely. Nothing here has a timer
 *     for reading.
 *
 * ## Arrival is not optional
 *
 * A stop that never resolves would leave the playhead in `travelling` for ever,
 * burning frames over a fleet of terminals that are each painting a canvas. So
 * arrival is guaranteed: {@link ARRIVE_GRACE_MS} after entering a stop, the tour
 * arrives regardless, marks the stop **degraded**, and says why — *"this one is
 * in vim; here is the text"*. `DRIVING-MODE.md` §2d is explicit that this beats
 * the alternative: *"a tour that quietly stops boxing is worse than one that
 * says why."*
 *
 * ## Two index spaces, and why there have to be two
 *
 * The record on disk is indexed by the **plan**: stop 0 is the first stop the
 * copilot wrote, for ever, whatever happens next. The playhead is indexed by
 * what is **currently playable**, because resuming after a long pause can find
 * that a session has closed and drop stops out of the middle. Collapsing the two
 * would mean either a record whose indices shuffle — so "stopped after 4 of 11"
 * names a different stop than it did an hour ago — or a playhead that has to
 * step over holes, which every selector in `pacer.ts` would need to learn about.
 *
 * So there is a plan, fixed, and an {@link order} into it. `order[playhead]` is
 * the record index. Two arrays and one lookup, in one file.
 *
 * ## What resuming re-checks, and what it cannot
 *
 * Resuming re-resolves the anchor before it moves, so a session that has since
 * closed, or a quote that has scrolled out of a buffer, drops rather than
 * pointing at nothing. It does **not** re-check the `why` — that is
 * `importance.ts`'s judgement, it lives in the main process against data this
 * window does not hold, and a second copy here is the exact duplication that
 * module exists to prevent. A tour is a briefing about the last few minutes; the
 * reasons were true when it was validated, and the honest thing this side can
 * add is whether the evidence is still on screen.
 */

import { clearFocus, setFocus, setLit } from '../../driving/focus-controller'
import {
  createAnchor,
  scrollToFocus,
  type FocusFailure,
  type FocusTarget,
} from '../../driving/focus-target'
import type { FocusReport } from '../../driving/FocusOverlay'
import { isPaceControlTarget, isTransportKey } from './interruption'
import { normalizeSpeed, type ReadingSpeed } from './estimate'
import { isRunning } from './pacer'
import { attachInterruption, browserPaceEngine, type PaceEngine } from './usePacer'
import { navigator as driveNavigator } from './navigator'
import {
  focusOf,
  paneFor,
  pacedOf,
  type TourMessage,
  type TourRecord,
  type TourStop,
} from './tour'
import type { PacerState } from './pacer'

/* ------------------------------------------------------------- constants -- */

/**
 * How long a stop may spend failing to resolve before the tour arrives anyway.
 *
 * Long enough to cover a whole navigation: a tab switch, a pane mode change,
 * `TerminalView`'s `ResizeObserver` firing, xterm refitting, and the overlay's
 * own 380 ms chase window on top of that. Short enough that a stop which
 * genuinely cannot be boxed — a session sitting in `vim`, a browser page, a
 * quote that has scrolled out of the buffer — does not read as the app having
 * hung before it says so.
 */
export const ARRIVE_GRACE_MS = 900

/**
 * A pause longer than this makes resuming re-check *every* remaining stop rather
 * than only the next one.
 *
 * Five minutes, from `DRIVING-MODE.md` §8. Under it, the stop being resumed onto
 * is the only one worth re-resolving; over it the fleet has moved on, and
 * walking somebody into four stops that are no longer there is worse than
 * telling them once that three of the remaining seven have gone.
 */
export const RESUME_STALE_MS = 5 * 60_000

/** The attribute the driving panel wears, so its own clicks do not pause. */
export const PANEL_ATTR = 'data-drive-panel'

/* ----------------------------------------------------------------- shapes -- */

/** What the panel draws: everything the pacing engine does not already say. */
export interface TourView {
  record: TourRecord
  /** The stops still playable, in play order. Indexes match the playhead. */
  stops: readonly TourStop[]
  /**
   * `recordIndexes[playheadIndex]` is that stop's index in the record.
   *
   * Published rather than left implicit because the two diverge the first time
   * a resume drops a stop out of the middle, and everything the panel reads out
   * of the record — the session's title, whether it has been shown — is keyed
   * the record's way. See the header for why there are two index spaces at all.
   */
  recordIndexes: readonly number[]
  pacer: PacerState
  /** Set while the stop on screen is navigable but not boxable. */
  degraded: { index: number; why: FocusFailure } | null
  /** Stops this window dropped on resume, on top of the ones main dropped. */
  droppedHere: Array<{ title: string; why: FocusFailure }>
  /** The reader stopped driving and asked for the rest as a list. */
  skimming: boolean
  ended: boolean
}

export type TourCommand = 'back' | 'toggle' | 'next' | 'stop' | 'skim'

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
  /** The reader's declared pace. */
  speed?: ReadingSpeed
  /** Injected for tests; a real frame-driven engine otherwise. */
  engine?: PaceEngine
  now?(): number
}

export interface RunningTour {
  view(): TourView
  subscribe(listener: () => void): () => void
  command(command: TourCommand): void
  /**
   * Go straight to a stop, by its index in {@link TourView.stops}.
   *
   * The manual override for "I want to see number seven again", and the reason
   * every row in the panel is a button. Clamped by `pacer.ts` rather than here,
   * so a click on a row that a resume has just dropped lands on the last stop
   * instead of ending the tour — `next` is the only thing allowed to walk off
   * the end.
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
  const engine = deps.engine ?? browserPaceEngine(normalizeSpeed(deps.speed))
  const listeners = new Set<() => void>()

  /** Fixed for the life of the tour. Indices here are the record's indices. */
  const plan: readonly TourStop[] = message.stops
  /** Which of them are still playable, in play order. See the header. */
  let order: number[] = plan.map((_, index) => index)

  let record: TourRecord = message.record
  let view: TourView = {
    record,
    stops: order.map((index) => plan[index]),
    recordIndexes: order,
    pacer: engine.getState(),
    degraded: null,
    droppedHere: [],
    skimming: false,
    ended: false,
  }

  /** Playhead index the screen is currently pointed at, or -1 before the first. */
  let pointedAt = -1
  /** Non-null while a stop is still travelling. Cleared on arrival. */
  let graceTimer: ReturnType<typeof setTimeout> | null = null
  /** The last failure the overlay reported for the stop being entered. */
  let lastFailure: FocusFailure | null = null
  let pausedAt: number | null = null
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
      pacer: engine.peek(),
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
              // Wall-clock from the moment the box was drawn: the reader's own
              // time, which is not the same as the estimate and is the only
              // number worth keeping. Null when the stop was never shown.
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
         * bringing it forward first shows one frame of the pane the reader is
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
       * rather than guessing. Point at the session's row instead, so the reader
       * is at least looking at the right session, and let the grace timer mark
       * it degraded.
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
   * already on screen moves the reader's page for no reason, which during a tour
   * reads as the app twitching.
   *
   * A chat bubble needs no equivalent here: `ChatView` watches the focus store
   * and scrolls its own scroller, because it is the only thing that can also
   * clear its stick-to-bottom flag — without which the next line of output on a
   * live session yanks the view back to the end while somebody is mid-sentence.
   */
  const scrollIfNeeded = (target: FocusTarget): void => {
    if (target.kind !== 'terminal') return
    try {
      scrollToFocus(createAnchor(target))
    } catch (error) {
      // A terminal mounted but not laid out can throw out of the measurement.
      // That is a degraded stop, not a broken tour.
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
   * Subscribing rather than driving it is what keeps every timing rule — the
   * hover hold, the stall detection, the learned speed — inside the pure module
   * where it can be tested against a fake clock.
   */
  const unsubscribe = engine.subscribe(() => {
    if (ended) return
    const state = engine.getState()

    if (state.status === 'finished') {
      finish()
      return
    }

    if (state.index !== pointedAt && isRunning(state)) {
      if (pointedAt >= 0) noteLeft(pointedAt, lastFailure)
      enterStop(state.index)
    }

    if (state.status === 'paused' && pausedAt === null) pausedAt = now()
    if (state.status !== 'paused' && pausedAt !== null) pausedAt = null

    publish()
  })

  /* --------------------------------------------------------- interruption -- */

  const watch = attachInterruption(engine, {
    window,
    document,
    now: () => performanceNow(),
    isOwnControl: (target) => isPaceControlTarget(target) || isPanelTarget(target),
    isCommandKey: isTransportKey,
    isHidden: () => document.visibilityState === 'hidden',
    // A collapsed selection is a focus change, not a person reading with a
    // finger on the page. Without this the panel taking focus paused the tour
    // before it had drawn its first box — see `hasSelection` in
    // `interruption.ts` for the whole of it.
    hasSelection: () => (document.getSelection()?.toString() ?? '') !== '',
  })

  /**
   * The four keys the tour owns while it is playing.
   *
   * Capture phase and `stopImmediatePropagation`, which is the part worth
   * justifying: during a tour these four chords belong to the tour, and letting
   * them through would type a space into whichever pty happens to hold focus.
   * That is the closest thing there is to driving mode typing into a session,
   * and `DRIVING-MODE.md` §7 spends a sentence on driving never typing.
   *
   * Scoped as tightly as it can be: only while a tour is running, only these
   * four keys, and only with no modifier held, so every ⌘ chord in the app still
   * works. The frame the tour ends, the keys go back.
   */
  const onKey = (event: KeyboardEvent): void => {
    if (ended || !isRunning(engine.peek())) return
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
      case 'skim':
        /*
         * Stop driving, keep the panel, hand over the rest as a list.
         *
         * The honest answer to a reader who is faster than the tour: the fastest
         * version of a tour is not a faster tour, it is the document. The focus
         * comes off because nothing is being pointed at any more — leaving a box
         * up over a list nobody is being walked through would be the overlay
         * outliving its reason.
         */
        publish({ skimming: true })
        engine.dispatch({ kind: 'pause', at, reason: 'asked' })
        clearFocus()
        return
      case 'stop':
        end()
    }
  }

  /**
   * Carry on — after re-checking that what was paused on is still there.
   *
   * `DRIVING-MODE.md` §8: resuming re-validates before it moves, and re-validates
   * *everything* remaining if the pause was long. What this side can answer is
   * whether the evidence is still on screen; the reasons were checked in the main
   * process and are not re-litigated here.
   */
  const resume = (): void => {
    const state = engine.peek()
    const stale = pausedAt !== null && now() - pausedAt > RESUME_STALE_MS
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
       * Redraw before starting the clock.
       *
       * Resuming has to leave the reader looking at the thing they paused on
       * rather than at the thing after it, and the overlay may have been moved
       * or taken down while they were away — so the stop is entered again, which
       * re-navigates, re-points and re-arrives, and only then does the engine's
       * resume take effect.
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
    // Where the reader lands: the same stop if it survived, otherwise the next
    // one that did. Counting the losses before `from` is what keeps that the
    // *same* stop rather than one shifted by however many vanished above it.
    const landing = Math.min(from - lost.filter((index) => index < from).length, kept.length - 1)
    order = kept
    publish({ droppedHere: [...view.droppedHere, ...dropped] })
    engine.dispatch({
      kind: 'play',
      at: performanceNow(),
      stops: order.map((index) => pacedOf(plan[index])),
      travel: true,
    })
    engine.dispatch({ kind: 'jump', at: performanceNow(), index: Math.max(0, landing), travel: true })
    enterStop(Math.max(0, landing))
  }

  /* -------------------------------------------------------------- the end -- */

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
       * A tour that reached its last stop has nothing to confess, and "stopped
       * after 11 of 11" is a sentence that makes a completed tour look
       * interrupted. Counted from the stops actually shown rather than from the
       * playhead, because the playhead moves during a rewind and the number
       * being reported is "how much did you see".
       */
      stoppedAfter: shown > 0 && shown < record.stops.length ? shown - 1 : null,
    }
    deps.report({ kind: 'ended', tourId: record.id, record })
    engine.destroy()
    publish()
  }

  const end = (): void => {
    if (ended) return
    engine.dispatch({ kind: 'stop', at: performanceNow() })
    finish()
  }

  /* ---------------------------------------------------------------- start -- */

  deps.report({ kind: 'started', tourId: record.id, record })
  engine.dispatch({
    kind: 'play',
    at: performanceNow(),
    stops: order.map((index) => pacedOf(plan[index])),
    travel: true,
  })
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
       * A jump pauses, and that is not the same decision `next` makes.
       *
       * Pressing → means "I have finished with this one" and the tour carries
       * on counting. Clicking a row three stops back means "wait, show me that
       * again", which is the same evidence a rewind carries — the reader missed
       * something, and answering that with another countdown is the wrong
       * response. `pacer.ts` draws the same line between → and ←.
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
 * Why there is no box, in the reader's terms.
 *
 * Every one of these is a state the design predicts and names, and each says
 * what is true rather than apologising. The `alternate-buffer` sentence is the
 * one `DRIVING-MODE.md` writes out itself: *"this one is in vim; here is the
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
