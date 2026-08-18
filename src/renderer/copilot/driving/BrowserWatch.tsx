import { useCallback, useEffect, useRef, useState } from 'react'
import {
  driveNowOf,
  driveStepOf,
  shortUrl,
  withStep,
  type DriveNow,
  type DriveStep,
} from './browser-trace'
import './browser-watch.css'

/**
 * The panel that shows the copilot working on a web page.
 *
 * *"Asked to scrape, it goes, shows the page and how it is scraping, then
 * returns with the result."* This is the middle clause. The page is the app's own
 * browser tab, open in the strip where anybody can see and close it; this sits in
 * the rail's column beside it and says what the driver is doing to it.
 *
 * `browser-trace.ts` carries the argument for why the showing is beside the page
 * rather than on it — the short version is that a page is a native
 * `WebContentsView` composited above the whole renderer, so nothing HTML can be
 * drawn over it, and the two tricks that would hide that (parking the page,
 * animating over a screenshot of it) were both refused: one removes what you came
 * to watch and the other is a picture pretending to be live.
 *
 * ## Every line here is something that happened
 *
 * The rows are the app's own action log, arriving as it is written. The line at
 * the top is the drive's own `step`, which the main process writes in the present
 * tense with the element's real label. Nothing is inferred, nothing is animated
 * to look busier than it is, and when the driver is between steps the live line
 * is simply not there — a spinner that kept moving would be this panel making a
 * claim about a process it is only reporting on.
 *
 * ## Where it is, and where it is not
 *
 * The rail's column, `position: fixed`, exactly like `DrivePanel` and for the
 * same load-bearing reason: a panel that pushed `.main` narrower would resize
 * every pty in the window. And it is **not drawn on the copilot's own page** —
 * the layout rule Asad stated twice, *"it should not make two split views on its
 * own page"*. There the copilot's own conversation is on screen, narrating the
 * same calls, and a second account of them in a panel beside it is the copilot
 * beside itself.
 *
 * It also stands down while a scan is playing. Both would want the same column,
 * and the scan is the one the person asked to watch.
 */

interface Props {
  /** Null once nothing is driving. The panel unmounts with it. */
  now: DriveNow | null
  steps: readonly DriveStep[]
  /**
   * Put the panel away and give the rail back.
   *
   * Not optional politeness — it is the difference between a report and an
   * obstruction. A drive does not end when a scrape finishes: `browser-driver.ts`
   * only releases the tab when the tab is *closed* or its process dies, so
   * without this the panel would sit over the sidebar from the first
   * `browser.open` until somebody thought to close the browser tab, and the rail
   * is how you reach every session in the app.
   *
   * It is deliberately not a per-panel "close for good": the drive is genuinely
   * still live and the copilot can act on that page at any moment, so the panel
   * comes back on the next errand. See {@link useBrowserWatch}.
   */
  onPutAway?: (() => void) | null
  name?: string
}

/**
 * A named handle on the panel, for anything that needs to find it.
 *
 * An attribute rather than the class name, on the rule `focus-target.ts` states:
 * a class is styling and belongs to whoever is working on this sheet, while an
 * attribute with no CSS attached to it is obviously a contract.
 *
 * Nothing reads it yet, and that is worth saying plainly rather than describing
 * a reader it does not have. It is not the scan's `PANEL_ATTR`: that one is what
 * `interruption.ts` checks before deciding a click took the screen back, and this
 * panel is never on screen while a scan is playing, so it has nothing to be
 * exempted from.
 */
export const WATCH_ATTR = 'data-browser-watch'

export function BrowserWatch({ now, steps, onPutAway = null, name }: Props) {
  const list = useRef<HTMLOListElement | null>(null)

  /*
   * Keep the newest row in view.
   *
   * Scoped to this list's own scroller. `scrollIntoView` would scroll the
   * *window*, and the window has a browser page in it that the copilot is in the
   * middle of driving.
   */
  useEffect(() => {
    const host = list.current
    if (host === null) return
    host.scrollTop = host.scrollHeight
  }, [steps.length])

  if (now === null) return null

  /*
   * The live URL, or the last one a completed call reported.
   *
   * Two sources for one fact, and the fallback is not belt-and-braces: the
   * drive's status is read off the `WebContents` at the moment it is published,
   * so between a tab being claimed and a page settling it is honestly empty, and
   * a heading reading "No page open yet" over a filling trace would be the panel
   * contradicting its own rows. The steps carry the URL the tool *returned*,
   * which is the address as it was when that call finished.
   *
   * Neither is a guess. When both are empty there genuinely is no page — the
   * drive has a tab and nothing in it — and the heading says exactly that.
   */
  const lastUrl = [...steps].reverse().find((step) => step.url !== '')?.url ?? ''
  const where = shortUrl(now.url) || shortUrl(lastUrl)

  return (
    <aside className="browser-watch" {...{ [WATCH_ATTR]: 'panel' }} aria-label="What it is doing">
      <header className="bw-head">
        <div className="bw-head-line">
          <p className="bw-kicker">{name === undefined ? 'Copilot' : name}</p>
          {onPutAway === null ? null : (
            /*
              The same round dot the driving panel wears, doing the same job:
              take the panel off the rail's column and give the rail back. One
              glyph with one meaning across both panels, rather than an ✕ here
              and a dot there — and an ✕ would be wrong anyway, because nothing
              is being closed. The drive is still live and the panel comes back
              on the copilot's next errand.
            */
            <button
              type="button"
              className="bw-fold"
              onClick={onPutAway}
              title="Put this away and show the sidebar"
              aria-label="Put this away and show the sidebar"
            >
              <span className="bw-fold-dot" aria-hidden="true" />
            </button>
          )}
        </div>
        <h2 className="bw-where">{where || 'No page open yet'}</h2>
      </header>

      {/*
        The live line, and nothing in its place when there is not one.

        `DriveStatus.step` is the only feedback a driven click has: CDP input
        does not move the operating system's pointer, so there is no cursor to
        watch, and the main process writes this sentence with the element's own
        label at the moment it dispatches. Between steps it is empty — and then
        this is empty too, rather than showing "working…", which would be the
        panel inventing activity to fill a gap.
      */}
      {now.step === '' ? null : (
        <p className="bw-now">
          <span className="bw-now-pip" aria-hidden="true" />
          {now.step}
        </p>
      )}

      {/*
        Handed over: the one state where this panel must say that it is showing
        nothing, rather than going quiet.

        While a person has the page, `browser-drive.ts` refuses the driver
        everything — including reads and screenshots — because you cannot redact
        what was never produced. So there is nothing to report and it says so, in
        the words of the guarantee: the trace stops because the reading stopped.
      */}
      {now.state === 'human' ? (
        <p className="bw-handover">
          The page is yours. Nothing it can see is being read or recorded while you have it.
        </p>
      ) : null}

      <ol className="bw-steps" ref={list}>
        {steps.map((step) => (
          <li key={step.id}>
            <div className="bw-step" data-outcome={step.outcome}>
              <p className="bw-step-what">{step.detail}</p>
              {/*
                The element the driver actually resolved, not the selector it was
                asked for. `browser.step` records the label it read off the page
                after resolving, and that is the fact worth showing: it says the
                click landed on the button a person can see.
              */}
              {step.element === '' ? null : <p className="bw-step-on">{step.element}</p>}
              {step.took === '' ? null : <p className="bw-step-took">{step.took}</p>}
              {step.error === '' ? null : <p className="bw-step-why">{step.error}</p>}
            </div>
          </li>
        ))}
      </ol>
    </aside>
  )
}

/**
 * The two subscriptions behind the panel, kept out of it.
 *
 * A hook rather than state inside `BrowserWatch`, because the panel is unmounted
 * for most of the app's life — on the copilot's own page, and while a scan is
 * playing — and a subscription that lived inside it would miss everything that
 * happened while it was away. The drive can start on the copilot's page and end
 * somewhere else entirely; the trace has to survive that.
 *
 * Both are guarded with `?.`, which is the harness rather than doubt about the
 * preload: `.harness/stub.ts` mounts this same tree against a stubbed bridge, and
 * a method it has not grown yet must leave the window running.
 */
export interface WatchBridge {
  onBrowserDriveState?(cb: (status: unknown) => void): () => void
  browserDriveStatus?(): Promise<unknown>
  onCopilotAction?(cb: (row: unknown) => void): () => void
}

export function useBrowserWatch(deck: WatchBridge | null): {
  now: DriveNow | null
  steps: DriveStep[]
  putAway: () => void
} {
  const [now, setNow] = useState<DriveNow | null>(null)
  const [steps, setSteps] = useState<DriveStep[]>([])
  /**
   * The tab this panel has been put away for, if any.
   *
   * Keyed on the tab rather than held as a bare boolean, because a drive is one
   * errand on one page — the tools have no `tabId` argument anywhere and calling
   * open again navigates the same tab — so "I have seen enough of this one" is a
   * statement about *that* page. A new tab is a new errand and gets the panel
   * back, without anything having to expire or be un-dismissed by hand.
   */
  const [putAwayFor, setPutAwayFor] = useState<string | null>(null)

  useEffect(() => {
    if (deck === null) return
    /*
     * Asked once as well as subscribed, because a push is not a queue: a window
     * that reloads in the middle of a drive would otherwise show nothing until
     * the driver's next step, and a drive parked on a handover makes no steps at
     * all — it is waiting for the person.
     */
    void deck.browserDriveStatus?.().then(
      (status) => setNow(driveNowOf(status)),
      () => {
        // No drive registered in this build. The panel simply never appears,
        // which is the honest answer rather than an empty one.
      },
    )
    return deck.onBrowserDriveState?.((status) => setNow(driveNowOf(status)))
  }, [deck])

  useEffect(() => {
    if (deck === null) return
    return deck.onCopilotAction?.((row) => {
      const step = driveStepOf(row)
      if (step === null) return
      setSteps((prev) => withStep(prev, step))
    })
  }, [deck])

  /*
   * The trace is emptied when the drive ends, not when the panel closes.
   *
   * A new scrape starting under the last one's rows would be two errands in one
   * list with nothing marking the seam. Ending is `idle` — `browser-drive.ts`
   * publishes it when the tab closes, when the drive is released, or when the
   * person takes the page and does not give it back.
   */
  const state = now?.state ?? 'idle'
  useEffect(() => {
    if (state === 'idle') setSteps([])
  }, [state])

  const putAway = useCallback(() => setPutAwayFor(now?.tabId ?? null), [now?.tabId])

  const live = now === null || now.state === 'idle' ? null : now
  return {
    // Put away for this page, or genuinely nothing driving. The panel cannot
    // tell those apart and does not need to: both mean "draw nothing", and the
    // rail is what is underneath either way.
    now: live !== null && live.tabId === putAwayFor ? null : live,
    steps,
    putAway,
  }
}
