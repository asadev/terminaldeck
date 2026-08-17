import { useCallback, useEffect, useRef, useState } from 'react'
import { DriveLayer } from '../../driving/DriveLayer'
import type { FocusReport } from '../../driving/FocusOverlay'
import { DrivePanel } from './DrivePanel'
import { loadSpeed, saveSpeed } from './reading-speed'
import { readTour } from './tour'
import { playTour, type RunningTour, type TourCommand, type TourView } from './tour-player'
import { DEFAULT_SPEED, type ReadingSpeed } from './estimate'

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
 * It also mounts the overlay, which is why `main.tsx` renders this instead of
 * `<DriveLayer/>` directly. The overlay's report — *did the box get drawn, and
 * if not, why not* — is what makes a tour arrive at a stop, so the two have to
 * be wired together somewhere, and doing it here keeps exactly one overlay in
 * the window. Two would each cut their own hole in their own scrim, and the
 * second one's scrim would dim the first one's hole.
 *
 * ## Why it holds the tour in a ref and not in state
 *
 * The player is not a value that re-renders; it is a running thing with a frame
 * loop, event listeners and a record. React state is the wrong home for it — a
 * re-render that recreated it would start a second tour on the same screen —
 * and the view it publishes is what state is for. So: the player in a ref, its
 * view in state, and one subscription between them.
 *
 * ## A tour never survives a reload
 *
 * There is nothing to do to get that, and that is the point of noting it. The
 * player is created in response to a message and lives in a ref; a reload
 * destroys the renderer and takes it with it. The main process notices
 * separately — `deck-control/index.ts` watches the window and closes the record
 * — so the two halves come to the same conclusion without either having to
 * trust the other. `DRIVING-MODE.md` §8: *"a tour that resumed itself after a
 * crash is a screen that starts moving on its own, which is the single
 * behaviour that would make somebody uninstall this."*
 */

/** The parts of the preload bridge driving mode uses. */
interface DriveBridge {
  onTour(handler: (tour: unknown) => void): () => void
  reportTour(report: unknown): Promise<unknown>
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
   * The reader's pace, read once at mount and held in a ref.
   *
   * A ref rather than state because nothing renders from it — the panel reads
   * the pace out of the pacer's own snapshot — and because it has to be
   * readable synchronously inside the tour listener, which fires whenever a
   * plan arrives rather than on a render. Reading it per tour instead would put
   * an await between the plan landing and the first box, which is the one moment
   * of this feature that must not have a gap in it.
   */
  const speed = useRef<ReadingSpeed>(DEFAULT_SPEED)
  useEffect(() => {
    let live = true
    void loadSpeed().then((stored) => {
      if (live) speed.current = stored
    })
    return () => {
      live = false
    }
  }, [])

  /*
   * The overlay's verdict, handed to whichever tour is running.
   *
   * Stable across renders, because `FocusOverlay` lists `onReport` in an effect
   * dependency array — a new function every render would re-run that effect on
   * every publish, and a publish happens ten times a second while a stop counts
   * down.
   */
  const reported = useCallback((report: FocusReport) => {
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
       * The main process refuses a second `tour.play` while one is live, so
       * this should not arrive — but "should not arrive" is not a mechanism,
       * and the failure it would cause is two players fighting over one focus
       * store, which on screen is a box that flickers between two places. The
       * previous one is ended rather than ignored, so whatever is on screen
       * belongs to the tour that is actually playing.
       */
      tour.current?.end()

      const running = playTour(parsed, {
        speed: speed.current,
        report: (payload) => {
          void deck.reportTour(payload).catch((error: unknown) => {
            /*
             * Not fatal, and not silent either.
             *
             * The tour is what the person asked for and the record is the
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
          /*
           * Keep what the tour learned about this reader.
           *
           * Written at the end rather than after every stop: the correction is
           * an EWMA that converges inside about four stops, so a write per stop
           * would be a dozen disk writes to persist a number that is still
           * settling. `pacer.ts` is deliberate about which behaviours count as
           * evidence — an early advance, a hover past the estimate, a rewind —
           * and this is where its conclusion is remembered.
           */
          speed.current = next.pacer.speed
          void saveSpeed(next.pacer.speed)
        }
      })
    })
  }, [deck])

  useEffect(() => {
    // A tour must not outlive the window's React tree either — an unmount here
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
   * this app is usually an xterm textarea — and then Space, which is the pause
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

  return (
    <>
      <DriveLayer onReport={reported} />
      {view === null ? null : <DrivePanel view={view} onCommand={command} onJump={jump} />}
    </>
  )
}
