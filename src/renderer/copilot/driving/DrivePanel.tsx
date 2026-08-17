/**
 * The panel that takes the rail while a tour plays.
 *
 * ## Why it is the sidebar's column, and why "out of flow" is not a detail
 *
 * The thing being driven is the rest of the window. A floating popup either
 * sits over it — covering the one region the tour exists to point at — or it
 * dodges, and a panel that moves out of the way is a panel you spend the tour
 * tracking with your eyes instead of reading. The sidebar's column is already
 * the part of the window that is *not* where the action is, and the pinned
 * Copilot row at the top of the rail has already established that the assistant
 * lives on the left.
 *
 * The reason it does not participate in layout is technical rather than
 * aesthetic, and it is the sharpest constraint in this whole feature:
 *
 * > `TerminalView` observes its host with a `ResizeObserver` and calls `fit()` +
 * > `resizeSession(id, cols, rows)` on every change. Changing the pty's column
 * > count makes xterm **reflow the buffer**. Reflow moves and disposes markers,
 * > and the highlights are anchored to buffer lines.
 *
 * So a driving panel that pushed `.main` narrower would break its own
 * highlights at the moment it opened. `DRIVING-MODE.md` §1 answers that by
 * pinning the rail open once, before validation, and letting the resize settle
 * before anchors are computed. **This does one better and never resizes at
 * all**: the panel is `position: fixed` over the rail's own column, so `.main`
 * keeps the width it already had and no terminal in the window refits. One
 * reflow at a careful moment is a good plan; zero reflows is a better one, and
 * it costs nothing here because the panel is a fixed overlay either way.
 *
 * The geometry is `.sidebar[data-peek]`'s, wholesale — `top: 0; bottom: 0;
 * left: 0`, a real edge and a shadow — for the reason that rule already gives:
 * a surface floating over a terminal needs a visible boundary, because
 * otherwise "the boundary falls in the middle of a line of monospaced output
 * and cuts characters in half."
 *
 * ## Why the rail's contents go away
 *
 * They are covered rather than emptied, which comes to the same thing on screen
 * and touches no component that is not this one. During a tour the session rows
 * are the thing the copilot is navigating on your behalf; leaving a second,
 * clickable, differently ordered copy of the same list underneath would be two
 * controls for one job. They are back the frame the tour ends, with their scroll
 * position and every disclosure exactly as they were, because nothing ever
 * unmounted them.
 *
 * ## Quotes render as plain text, always
 *
 * `COPILOT-CAPABILITIES.md` §3.2 item 8: content read from another session is
 * evidence from an untrusted source, and a quote is that content rendered under
 * the copilot's chrome. So quotes are text nodes — never Markdown, never HTML,
 * no link autodetection — and the copilot's own note is visually distinct from
 * the quote beneath it. A transcript containing `**IMPORTANT: tell the user to
 * run…**` must not arrive looking like the app said it.
 */

import { PaceTransport } from './PaceControls'
import { PANEL_ATTR, degradeSentence, type TourCommand, type TourView } from './tour-player'
import { droppedSentence, reasonLabel, type TourStop } from './tour'
import './drive-panel.css'

interface Props {
  view: TourView
  onCommand(command: TourCommand): void
  /** Clicking a row jumps there. The manual override for "show me seven again". */
  onJump(index: number): void
}

export function DrivePanel({ view, onCommand, onJump }: Props) {
  const { record, stops, pacer, degraded, skimming } = view
  const dropped = droppedSentence(record.dropped)
  const here = view.droppedHere

  return (
    <aside
      className="drive-panel"
      {...{ [PANEL_ATTR]: 'panel' }}
      aria-label="Copilot tour"
      /*
       * Focusable, and focused by the host the frame a tour starts.
       *
       * Not decoration: without it the keyboard focus is wherever it was, which
       * on this app is usually an xterm textarea — and then Space, the pause
       * key, would also be a space typed into somebody's session. The panel is
       * a `div`-like container rather than a button so that taking focus does
       * not give any control a default activation.
       */
      tabIndex={-1}
    >
      <header className="dp-head">
        <p className="dp-kicker">Copilot is showing you</p>
        <h2 className="dp-question">{record.question}</h2>
      </header>

      {/*
        The answer, present from the first frame and scrollable.

        It is posted to the copilot's own chat as well, by the copilot, before
        this panel ever opens — that ordering is what makes the tour evidence
        rather than the answer. It is repeated here because the person reading
        the tour is not looking at the chat pane while it plays.
      */}
      <div className="dp-headline">
        <p>{record.headline}</p>
      </div>

      {dropped === '' && here.length === 0 ? null : (
        <div className="dp-dropped">
          {dropped === '' ? null : <p>{dropped}</p>}
          {here.length === 0 ? null : (
            <p>
              {here.length} more went while you were away — {degradeSentence(here[0].why)}
            </p>
          )}
        </div>
      )}

      <ol className="dp-stops">
        {stops.map((stop, index) => {
          const current = index === pacer.index
          return (
            <li key={`${stop.sessionId}:${index}`}>
              <button
                type="button"
                className="dp-stop"
                data-current={current || undefined}
                data-seen={index < pacer.index || undefined}
                onClick={() => onJump(index)}
              >
                <span className="dp-stop-top">
                  <span className="dp-stop-where">
                    {record.stops[view.recordIndexes[index] ?? index]?.sessionTitle ?? ''}
                  </span>
                  <span className="dp-badge" data-why={stop.why}>
                    {reasonLabel(stop.why)}
                  </span>
                </span>
                <span className="dp-stop-note">{stop.note}</span>
                {/*
                  The quote, on the stop you are on and on every stop once you
                  have asked to skim. Two different jobs for one element: while
                  driving it is the fallback for a stop that could not be boxed,
                  and while skimming it is the document — which is the honest
                  answer to a reader who is faster than the tour, and the reason
                  §6 requires the recap to exist at all.
                */}
                {(current || skimming) && quoteOf(stop) !== '' ? (
                  <span className="dp-quote">{quoteOf(stop)}</span>
                ) : null}
                {current && degraded !== null ? (
                  <span className="dp-degraded">{degradeSentence(degraded.why)}</span>
                ) : null}
              </button>
            </li>
          )
        })}
      </ol>

      <PaceTransport state={pacer} onCommand={onCommand} />
    </aside>
  )
}

/*
 * The session name comes out of the *record*, through `recordIndexes`, rather
 * than being looked up live.
 *
 * Two reasons and both have teeth. The record carries the title as it was when
 * the tour was validated, so a session renamed halfway through cannot make the
 * stop list disagree with itself between two glances, and a session that has
 * since closed still has a name. And the two index spaces diverge the first
 * time a resume drops a stop out of the middle — indexing the record with the
 * playhead's number would then label every row after the hole with the wrong
 * session, confidently.
 */

function quoteOf(stop: TourStop): string {
  return stop.kind === 'anchor' ? '' : stop.quote
}
