import { useCallback, useEffect, useRef, useState } from 'react'
import { DRIVE_CONTROL_ATTR } from './interruption'
import { PANEL_ATTR, degradeSentence, type TourCommand, type TourView } from './tour-player'
import { droppedSentence, reasonLabel, type TourStop } from './tour'
import { isScanning, scanProgress, statusSentence } from '../../../shared/scan'
import './drive-panel.css'

/**
 * The side panel — which, while driving, **is** the copilot.
 *
 * Asad, 2026-08-17:
 *
 *   > *"While driving, the side panel is the copilot: its chat box is there,
 *   > continuously talking, and he can navigate to other pages and bring it
 *   > back."*
 *
 * So this is not a transport bar with a progress ring any more. It is where the
 * copilot lives for the duration: it says what it is looking at as it goes, it
 * keeps the trace of everywhere it has been, and it has a chat box you can type
 * into without stopping to go and find the copilot's own window.
 *
 * ## The layout rule, which he stated twice
 *
 *   > *"When it is interacting it is making two split views even inside its own
 *   > page. It should not make two split views on its own page."*
 *
 * **On the copilot's own page there is no panel at all** — the page is already
 * the copilot, and a side panel there is the copilot beside itself. That
 * decision is not made here, because this component cannot see what is in front;
 * `DriveHost` makes it, and `driving/where.ts` is the one place that answers
 * the question. This file only has to be small enough that mounting it
 * conditionally costs nothing.
 *
 * ## Why it is the sidebar's column, and why "out of flow" is not a detail
 *
 * The thing being driven is the rest of the window. A floating popup either sits
 * over it — covering the one region the scan exists to point at — or it dodges,
 * and a panel that moves out of the way is a panel you spend the scan tracking
 * with your eyes. The sidebar's column is already the part of the window that is
 * *not* where the action is, and the pinned Copilot row at the top of the rail
 * has already established that the assistant lives on the left.
 *
 * The reason it does not participate in layout is technical rather than
 * aesthetic, and it is the sharpest constraint in this whole feature:
 *
 * > `TerminalView` observes its host with a `ResizeObserver` and calls `fit()` +
 * > `resizeSession(id, cols, rows)` on every change. Changing the pty's column
 * > count makes xterm **reflow the buffer**. Reflow moves and disposes markers,
 * > and the highlights are anchored to buffer lines.
 *
 * So a driving panel that pushed `.main` narrower would break its own highlights
 * at the moment it opened. This never resizes at all: the panel is
 * `position: fixed` over the rail's own column, so `.main` keeps the width it
 * already had and no terminal in the window refits.
 *
 * ## What the trace is for
 *
 * At 260 ms a stop, nobody follows the boxes. What a person *can* follow is a
 * list filling up — so the trace is the machine's own account of where it has
 * been, written as it goes, and every row is clickable because clicking back
 * into it is the only way to actually look at a single stop while the scan is
 * still running. That is the honest answer to "it is too fast to read": it is
 * meant to be. The reading happens afterwards, in the answer.
 *
 * ## Quotes render as plain text, always
 *
 * Content read from another session is evidence from an untrusted source, and a
 * quote is that content rendered under the copilot's chrome. So quotes are text
 * nodes — never Markdown, never HTML, no link autodetection — and the copilot's
 * own note is visually distinct from the quote beneath it. A transcript
 * containing `**IMPORTANT: tell the user to run…**` must not arrive looking like
 * the app said it.
 */

interface Props {
  view: TourView
  onCommand(command: TourCommand): void
  /** Clicking a row jumps there. The manual override for "show me that again". */
  onJump(index: number): void
  /**
   * Send a line to the copilot's own session, as if typed in its window.
   *
   * Null when there is no copilot session to talk to, in which case the chat box
   * is not drawn at all rather than drawn dead. A composer that swallows what
   * somebody typed is worse than no composer.
   */
  onSay?: ((text: string) => void) | null
  /** Fold the copilot back to its own window. The dot beside its name does this. */
  onFold?: (() => void) | null
  /**
   * Turn the showing off, from the one moment somebody wants it off.
   *
   * Interactive mode is a setting the main process reads before it stages a
   * scan, and it is off-limits to the copilot. But the instant a person decides
   * they would rather not watch this is **while they are watching it**, and
   * making them stop, find Settings and hunt for a checkbox is how a preference
   * goes unexpressed. So the control is here, in the scan's own panel, and it
   * says what it does: the work still happens, the answer is unchanged, the
   * screen stays still next time.
   *
   * Null when there is no bridge to write the setting through, in which case
   * nothing is drawn rather than drawn dead.
   */
  onQuiet?: (() => void) | null
  name?: string
}

export function DrivePanel({
  view,
  onCommand,
  onJump,
  onSay = null,
  onFold = null,
  onQuiet = null,
  name,
}: Props) {
  const { record, stops, scan, degraded } = view
  const dropped = droppedSentence(record.dropped)
  const here = view.droppedHere
  const running = isScanning(scan)
  const trace = useRef<HTMLOListElement | null>(null)

  /*
   * Keep the newest row in view.
   *
   * The trace is the one thing on screen moving at a speed a person can follow,
   * and a list that fills past its own bottom edge stops being that. Scoped to
   * the panel's own scroller — `scrollIntoView` on the element would scroll the
   * *window*, and the window is being driven by something else entirely.
   */
  useEffect(() => {
    const host = trace.current
    if (host === null) return
    const row = host.querySelector<HTMLElement>('[data-current]')
    if (row === null) return
    const top = row.offsetTop
    const bottom = top + row.offsetHeight
    if (bottom > host.scrollTop + host.clientHeight) host.scrollTop = bottom - host.clientHeight
    else if (top < host.scrollTop) host.scrollTop = top
  }, [scan.index, scan.seen.length])

  return (
    <aside
      className="drive-panel"
      {...{ [PANEL_ATTR]: 'panel' }}
      aria-label={name === undefined ? 'Copilot' : name}
      /*
       * Focusable, and focused by the host the frame a scan starts.
       *
       * Not decoration: without it the keyboard focus is wherever it was, which
       * on this app is usually an xterm textarea — and then Space, the hold key,
       * would also be a space typed into somebody's session. The panel is a
       * container rather than a button so that taking focus does not give any
       * control a default activation.
       */
      tabIndex={-1}
    >
      <header className="dp-head">
        <div className="dp-head-line">
          <p className="dp-kicker">{name === undefined ? 'Copilot' : name}</p>
          {onFold === null ? null : (
            <button
              type="button"
              className="dp-fold"
              {...{ [DRIVE_CONTROL_ATTR]: 'fold' }}
              onClick={onFold}
              title="Open the copilot’s own window"
              aria-label="Open the copilot’s own window"
            >
              {/* The same round dot that sits beside its name in the rail, doing
                  the same job from the other side: there it folds the copilot
                  into this panel, here it opens the window back up. One glyph,
                  one meaning, both directions. */}
              <span className="dp-fold-dot" aria-hidden="true" />
            </button>
          )}
        </div>
        <h2 className="dp-question">{record.question}</h2>
      </header>

      {/*
        A bar that fills across the whole scan rather than a ring that fills
        across one stop.

        The ring it replaces was a promise about when the app would move on,
        which a reader needed and a watcher does not — at machine speed the only
        interesting question is how much of the fleet is left. It is also the
        one element that makes a scan of three stops and a scan of twelve look
        like different lengths of thing, which they are.
      */}
      <div className="dp-progress" role="presentation">
        <span className="dp-progress-fill" style={{ transform: `scaleX(${scanProgress(scan)})` }} />
      </div>

      <ol className="dp-stops" ref={trace}>
        {stops.map((stop, index) => {
          const current = index === scan.index
          const visited = scan.seen.includes(index)
          return (
            <li key={`${stop.sessionId}:${index}`}>
              <button
                type="button"
                className="dp-stop"
                {...{ [DRIVE_CONTROL_ATTR]: 'stop-row' }}
                data-current={current || undefined}
                data-seen={(!current && visited) || undefined}
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
                  The quote, on the stop it is looking at right now.

                  Not on every row: at this speed the panel would be a wall of
                  other people's terminal output scrolling past, which is the
                  exact thing the scan exists to save somebody from reading. The
                  full text of every stop is in the answer afterwards, which is
                  where reading belongs.
                */}
                {current && quoteOf(stop) !== '' ? (
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

      {dropped === '' && here.length === 0 ? null : (
        <div className="dp-dropped">
          {dropped === '' ? null : <p>{dropped}</p>}
          {here.length === 0 ? null : (
            <p>
              {here.length} more went while it was held — {degradeSentence(here[0].why)}
            </p>
          )}
        </div>
      )}

      <div className="dp-foot" {...{ [DRIVE_CONTROL_ATTR]: 'transport' }}>
        <p className="dp-status">{statusSentence(scan)}</p>
        <div className="dp-transport">
          <button type="button" onClick={() => onCommand('back')} title="Back one" aria-label="Back one">
            ←
          </button>
          <button
            type="button"
            onClick={() => onCommand('toggle')}
            title={scan.status === 'paused' ? 'Carry on' : 'Hold'}
            aria-label={scan.status === 'paused' ? 'Carry on' : 'Hold'}
          >
            {scan.status === 'paused' ? '▶' : '❙❙'}
          </button>
          <button
            type="button"
            onClick={() => onCommand('next')}
            title="Forward one"
            aria-label="Forward one"
          >
            →
          </button>
          <button type="button" className="dp-end" onClick={() => onCommand('stop')}>
            {running ? 'Stop' : 'Close'}
          </button>
        </div>
        {onQuiet === null ? null : (
          <button type="button" className="dp-quiet" onClick={onQuiet}>
            Don’t show me next time
          </button>
        )}
      </div>

      {onSay === null ? null : <DriveComposer onSay={onSay} />}
    </aside>
  )
}

/**
 * The chat box, in the panel, talking to the copilot's real session.
 *
 * *"While driving, the side panel is the copilot: its chat box is there."* This
 * is that, and it is the real one — what is typed here goes down the copilot's
 * own pty through the same bridge its window uses, so the turn lands in the
 * copilot's own transcript and its own window shows it. There is no second
 * conversation and nothing is injected into a transcript from outside: the app
 * must never author the copilot's words, which is the same rule that keeps the
 * scan's record in a folder the copilot cannot write to.
 *
 * Typing does not stop the scan. Every other keystroke in the window does — that
 * is the whole promise of the interruption watch — so this composer wears the
 * driving-control attribute, which is the one exemption the watch offers. Asking
 * the copilot something while watching it work is not taking the screen back.
 */
function DriveComposer({ onSay }: { onSay: (text: string) => void }) {
  const [text, setText] = useState('')

  const send = useCallback(() => {
    const trimmed = text.trim()
    if (trimmed === '') return
    onSay(trimmed)
    setText('')
  }, [onSay, text])

  return (
    <form
      className="dp-say"
      {...{ [DRIVE_CONTROL_ATTR]: 'composer' }}
      onSubmit={(event) => {
        event.preventDefault()
        send()
      }}
    >
      <input
        className="dp-say-input"
        value={text}
        placeholder="Ask while it works…"
        aria-label="Say something to the copilot"
        onChange={(event) => setText(event.target.value)}
        /*
         * The keys the scan owns are dispatched at the window in the capture
         * phase, so Space and the arrows would never reach this field. Stopping
         * propagation here — before the window's own handler — is what makes a
         * space bar type a space while a scan is playing rather than hold it.
         */
        onKeyDown={(event) => event.stopPropagation()}
      />
      <button type="submit" className="dp-say-send" aria-label="Send">
        ↑
      </button>
    </form>
  )
}

/*
 * The session name comes out of the *record*, through `recordIndexes`, rather
 * than being looked up live.
 *
 * Two reasons and both have teeth. The record carries the title as it was when
 * the tour was validated, so a session renamed halfway through cannot make the
 * trace disagree with itself between two glances, and a session that has since
 * closed still has a name. And the two index spaces diverge the first time a
 * recount drops a stop out of the middle — indexing the record with the
 * playhead's number would then label every row after the hole with the wrong
 * session, confidently.
 */

function quoteOf(stop: TourStop): string {
  return stop.kind === 'anchor' ? '' : stop.quote
}
