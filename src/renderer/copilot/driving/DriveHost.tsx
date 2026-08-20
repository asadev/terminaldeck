import { useCallback, useEffect, useRef, useState } from 'react'
import { DriveLayer } from '../../driving/DriveLayer'
import type { FocusReport } from '../../driving/FocusOverlay'
import { ScanField, type Rect } from '../../driving/ScanField'
import { publishWhere, watchCopilotFrontmost } from '../../driving/where'
import { driveNowOf, type DriveNow } from './browser-trace'
import { DrivePanel } from './DrivePanel'
import { setRailCopilot, setRailDrive } from './rail-panel'
import { readTour } from './tour'
import { playTour, type RunningTour, type TourCommand, type TourView } from './tour-player'

/**
 * Driving mode, mounted once for the window.
 *
 * ## Where this goes, and why it is not inside `<App/>`
 *
 * `main.tsx`, as a sibling of `<App/>` inside `#root` — the same position, for
 * the same three reasons, that `DriveLayer.tsx` already argues for at length:
 *
 * 1. **It takes no part in the layout.** `.app` is a flex row of the rail and
 *    the work; a fixed overlay is neither. More sharply here than for the
 *    overlay: a panel inside that row would push `.main` narrower, every
 *    `TerminalView` would refit, every pty would resize, and xterm would reflow
 *    the buffers the highlights are anchored to. The panel would break its own
 *    boxes at the moment it opened.
 * 2. **It stays inside `#root` rather than being portalled into `<body>`**,
 *    because `overlay-watch.ts` treats every body child with a box as a
 *    floating surface and parks any browser page underneath it.
 * 3. **`App.tsx` is on the parallel-agent forbidden list and `main.tsx` is
 *    not.** A coincidence, and a convenient one.
 *
 * It mounts three things, and the split between them is the design:
 *
 *  - **the overlay**, which cuts the hole and dulls the rest;
 *  - **the dot field**, which is what the dulled part carries — *"the
 *    non-focused areas carry the dots treatment; the focus is what stays
 *    clear"*;
 *  - **the scan's panel**, which while a scan is playing *is* the copilot.
 *
 * It also **publishes** two things it cannot draw: the browser drive's live
 * status and the copilot's session id. The panel that shows a scrape used to be
 * mounted here beside the scan's, and on 2026-08-21 it moved into the sidebar —
 * it has to be the rail's real width and it has to know what the window is
 * showing, and neither is answerable from a fixed overlay in this tree. What
 * stays here is the subscription, because the panel is unmounted for most of the
 * app's life and a subscription living inside it would miss everything that
 * happened while it was away. See `rail-panel.ts`.
 *
 * ## The layout rule, enforced here because this is the only place that can
 *
 *   > *"When it is interacting it is making two split views even inside its own
 *   > page. It should not make two split views on its own page."*
 *
 * So: on the copilot's own window there is **no panel**. The page is already the
 * copilot; a side panel there is the copilot beside itself, and it is the exact
 * thing he objected to twice. The overlay and the field still run — the scan is
 * still driving the screen, and a scan with no visible machinery is worse than
 * one with a panel in the wrong place.
 *
 * It is watched rather than read once, because a scan navigates: it walks *off*
 * the copilot's page at the first stop and back *onto* it at the end, and the
 * panel has to appear and disappear with it. Watched with a `MutationObserver`
 * on the rail's own row rather than re-read on every publish, because a **held**
 * scan publishes nothing — and folding the copilot back while the screen is
 * stopped is exactly when somebody would notice the panel had stayed.
 *
 * ## Why it holds the tour in a ref and not in state
 *
 * The player is not a value that re-renders; it is a running thing with a frame
 * loop, event listeners and a record. React state is the wrong home for it — a
 * re-render that recreated it would start a second scan on the same screen — and
 * the view it publishes is what state is for. So: the player in a ref, its view
 * in state, and one subscription between them.
 *
 * ## A tour never survives a reload
 *
 * There is nothing to do to get that, and that is the point of noting it. The
 * player is created in response to a message and lives in a ref; a reload
 * destroys the renderer and takes it with it. The main process notices
 * separately — `deck-control/index.ts` watches the window and closes the record
 * — so the two halves come to the same conclusion without either having to trust
 * the other. *"A tour that resumed itself after a crash is a screen that starts
 * moving on its own, which is the single behaviour that would make somebody
 * uninstall this."*
 */

/** The parts of the preload bridge driving mode uses. */
interface DriveBridge {
  onTour(handler: (tour: unknown) => void): () => void
  reportTour(report: unknown): Promise<unknown>
  copilotState?(): Promise<unknown>
  writeToSession?(id: string, data: string): void
  setSettings?(patch: Record<string, unknown>): Promise<unknown>
  /**
   * The browser drive's own live status.
   *
   * Optional, and guarded with `?.` at every call — which is the harness rather
   * than doubt about the preload: `.harness/stub.ts` mounts this same tree
   * against a stubbed bridge, and a method it has not grown yet must leave the
   * window running.
   */
  onBrowserDriveState?(cb: (status: unknown) => void): () => void
  browserDriveStatus?(): Promise<unknown>
}

function bridge(): DriveBridge | null {
  const deck = (globalThis as { deck?: Partial<DriveBridge> }).deck
  if (!deck || typeof deck.onTour !== 'function' || typeof deck.reportTour !== 'function') return null
  return deck as DriveBridge
}

export function DriveHost({ deck = bridge() }: { deck?: DriveBridge | null }) {
  const tour = useRef<RunningTour | null>(null)
  const [view, setView] = useState<TourView | null>(null)

  /*
   * The hole, written every time the overlay re-measures and read by the field
   * every frame.
   *
   * A ref rather than state, and it is the difference between this feature
   * costing nothing and costing a re-render per frame: the rectangle changes
   * whenever a terminal repaints, which on a streaming session is sixty times a
   * second, and the only thing that needs the new number is a canvas that is
   * being redrawn anyway.
   */
  const hole = useRef<Rect | null>(null)

  /**
   * The copilot's own session id, so a finished scan can go back to its chat.
   *
   * Read once at mount and kept in a ref. It has to be readable synchronously
   * inside the tour listener — which fires when a plan arrives, not on a render
   * — and putting an await between the plan landing and the first box is the one
   * moment of this feature that must not have a gap in it.
   */
  const copilotId = useRef<string | null>(null)
  useEffect(() => {
    if (deck?.copilotState === undefined) return
    let live = true
    void deck
      .copilotState()
      .then((state) => {
        if (!live) return
        const raw = state as { sessionId?: unknown } | null
        copilotId.current = typeof raw?.sessionId === 'string' ? raw.sessionId : null
        // And published, because the rail's panel needs it too and cannot read
        // a ref in another tree. It is the panel's *fallback* subject — the
        // session bound to the page wins — so a build with no copilot simply
        // leaves it null. See `rail-panel.ts`.
        setRailCopilot(copilotId.current)
      })
      .catch(() => {
        // No copilot, or the read failed. The scan then simply ends where it is
        // rather than navigating somewhere it cannot name, which is honest: the
        // answer is still written to the record either way.
      })
    return () => {
      live = false
    }
  }, [deck])

  /* Publish the "where am I" reader for the whole life of the window. */
  useEffect(() => publishWhere(), [])

  /*
   * The layout rule, as state rather than as a read during render.
   *
   * Read-during-render is only as current as the last render, and a **held**
   * scan publishes nothing — so folding the copilot back to its own window while
   * the screen is stopped would leave the panel up, which is the copilot beside
   * itself. Watching the attribute instead makes the panel appear and disappear
   * with the navigation, whatever the playhead is doing.
   */
  const [copilotFront, setCopilotFront] = useState(false)
  useEffect(() => watchCopilotFrontmost(setCopilotFront), [])

  /*
   * The overlay's verdict, handed to whichever tour is running.
   *
   * Stable across renders, because `FocusOverlay` lists `onReport` in an effect
   * dependency array — a new function every render would re-run that effect on
   * every publish.
   */
  const reported = useCallback((report: FocusReport) => {
    hole.current = report.rect
    tour.current?.reported(report)
  }, [])

  useEffect(() => {
    if (deck === null) return
    return deck.onTour((message) => {
      const parsed = readTour(message)
      if (parsed === null) return
      /*
       * One tour at a time.
       *
       * The main process refuses a second `tour.play` while one is live, so this
       * should not arrive — but "should not arrive" is not a mechanism, and the
       * failure it would cause is two players fighting over one focus store,
       * which on screen is a box that flickers between two places. The previous
       * one is ended rather than ignored, so whatever is on screen belongs to
       * the scan that is actually playing.
       */
      tour.current?.end()

      const running = playTour(parsed, {
        copilotSessionId: copilotId.current,
        report: (payload) => {
          void deck.reportTour(payload).catch((error: unknown) => {
            /*
             * Not fatal, and not silent either.
             *
             * The scan is what the person asked for and the record is the
             * account of it, so a record that cannot be written must not stop
             * the screen mid-stop. But this was written silent first, and the
             * silence cost an hour: the *first* thing a player says is
             * `started`, which is what the main process waits on before it
             * believes a tour is playing — so a rejection here does not lose a
             * line of an audit file, it makes `tour.play` answer "the window was
             * given the tour and did not start it" with nothing anywhere saying
             * why. A failure that is survivable still has to be legible.
             */
            console.error('[driving] could not report on the tour:', error)
          })
        },
      })
      tour.current = running
      setView(running.view())
      const off = running.subscribe(() => {
        const next = running.view()
        setView(next)
        if (next.ended) {
          off()
          if (tour.current === running) tour.current = null
          setView(null)
          hole.current = null
        }
      })
    })
  }, [deck])

  useEffect(() => {
    // A scan must not outlive the window's React tree either — an unmount here
    // means the app is being torn down, and a frame loop plus four
    // capture-phase window listeners left behind would be the leak this whole
    // module is careful about everywhere else.
    return () => {
      tour.current?.end()
      tour.current = null
    }
  }, [])

  /*
   * Focus the panel the moment it appears.
   *
   * Not cosmetic. Without it the keyboard focus stays wherever it was, which in
   * this app is usually an xterm textarea — and then Space, which is the hold
   * key, is also a space typed into somebody's session. The player's own
   * capture-phase handler stops the key reaching the terminal, but focus is the
   * belt to that brace, and it is also what makes the panel's rows reachable by
   * Tab without hunting.
   */
  const playing = view !== null
  useEffect(() => {
    if (!playing) return
    document.querySelector<HTMLElement>('[data-drive-panel]')?.focus()
  }, [playing])

  const command = useCallback((name: TourCommand) => {
    tour.current?.command(name)
  }, [])

  const jump = useCallback((index: number) => {
    tour.current?.jump(index)
  }, [])

  /**
   * Say something to the copilot without leaving the scan.
   *
   * Written straight down the copilot's own pty, which is what its own window
   * does — so the turn lands in the copilot's real transcript and there is no
   * second conversation anywhere. Null when there is no copilot session or no
   * bridge, in which case the panel draws no chat box at all: a composer that
   * swallows what somebody typed is worse than no composer.
   */
  const say = useCallback(
    (text: string) => {
      const id = copilotId.current
      if (id === null || deck?.writeToSession === undefined) return
      deck.writeToSession(id, `${text}\r`)
    },
    [deck],
  )

  /**
   * Open the copilot's own window — what the round dot beside its name does.
   *
   * Reached through the rail's own row rather than through a navigation call,
   * because the rail row *is* the app's answer to "open the copilot" and going
   * around it would be a second one. `tour-player.ts` uses the navigator for the
   * same journey at the end of a scan; this is the manual version of it, and
   * both end in the same place.
   */
  const fold = useCallback(() => {
    document.querySelector<HTMLElement>('[data-copilot-row] button, button[data-copilot-row]')?.click()
  }, [])

  /**
   * Turn the showing off and stop this one.
   *
   * The setting is what `tour.play` reads before it stages anything, so writing
   * it here is the same switch Settings would flip — there is no second flag and
   * no renderer-side branch that could disagree with the main-process one. The
   * scan then ends, because leaving it running after somebody said they would
   * rather not watch would be answering "not this" with "this, one more time".
   */
  const quiet = useCallback(() => {
    void deck?.setSettings?.({ 'copilot.interactive': false })?.catch((error: unknown) => {
      console.error('[driving] could not turn interactive mode off:', error)
    })
    tour.current?.end()
  }, [deck])

  const canSay = view !== null && copilotId.current !== null && deck?.writeToSession !== undefined

  /**
   * The other thing the copilot drives, and the other way of showing it.
   *
   * *"Asked to scrape, it goes, shows the page and how it is scraping, then
   * returns with the result."* A scan and a scrape are the same promise about two
   * different subjects, so they share this host, the rail's column and the glass
   * — and they are never up together, because they would want the same column and
   * the scan is the one somebody asked to watch.
   *
   * Subscribed **here** rather than in the panel that draws it, because the
   * panel is unmounted for most of the app's life — it is only on screen while
   * the page being driven is in front, and the rail it lives in is unmounted
   * altogether while the sidebar is collapsed. A subscription living inside it
   * would miss everything that happened while it was away, and a drive can begin
   * on the copilot's own page and end somewhere else entirely.
   *
   * Asked once as well as subscribed, because a push is not a queue: a window
   * that reloads in the middle of a drive would otherwise show nothing until the
   * driver's next step, and a drive parked on a handover makes no steps at all —
   * it is waiting for the person.
   */
  const [now, setNow] = useState<DriveNow | null>(null)
  useEffect(() => {
    if (deck === null) return
    void deck.browserDriveStatus?.().then(
      (status) => setNow(driveNowOf(status)),
      () => {
        // No drive registered in this build. The panel simply never appears,
        // which is the honest answer rather than an empty one.
      },
    )
    return deck.onBrowserDriveState?.((status) => setNow(driveNowOf(status)))
  }, [deck])

  /*
   * Published for the rail, and withheld while a scan is playing.
   *
   * The two would want the same column and the scan is the one somebody asked to
   * watch, so the drive is published as `null` for its duration rather than the
   * panel growing a second rule about a feature it cannot see. Everything else
   * about when the panel is drawn — the page in front, the fold — is decided in
   * `rail-panel.ts`, in one function, so nothing has to agree with anything.
   */
  useEffect(() => {
    setRailDrive(view === null ? now : null)
  }, [now, view])

  return (
    <>
      <DriveLayer onReport={reported} />
      <ScanField
        hole={hole}
        active={view !== null}
        seen={view?.scan.seen.length ?? 0}
        count={view?.scan.count ?? 0}
        pulse={view?.scan.arrivals ?? 0}
      />
      {view === null || copilotFront ? null : (
        <DrivePanel
          view={view}
          onCommand={command}
          onJump={jump}
          onSay={canSay ? say : null}
          onFold={fold}
          onQuiet={deck?.setSettings === undefined ? null : quiet}
        />
      )}
      {/*
        The scrape's panel is not mounted here any more.

        It used to be a fixed overlay in this tree, beside the scan's, and that
        placement was the whole of what he objected to on 2026-08-21: it floated
        over the rail at a token width instead of taking the rail's column, and
        it was drawn on every page in the app because nothing in this tree knows
        what the window is showing. It is now a child of the sidebar
        (`CopilotRailPanel`), which is the only place it can be the rail's real
        width; this host keeps what only it can have — the subscription, which
        has to outlive a panel that is unmounted most of the time.
      */}
    </>
  )
}
