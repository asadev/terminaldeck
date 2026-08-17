/**
 * The controls, which are the half of pacing a reader can see.
 *
 * Two surfaces, and they answer the two halves of what Asad asked for:
 *
 * - `PaceTransport` — back, pause, next, stop, and **how much longer**. Present
 *   from the first frame of a tour to the last, never conditional, never
 *   collapsed into an overflow menu.
 * - `ReadingSpeedControl` — the preference, in names rather than numbers.
 *
 * ## Why the progress is not a nicety
 *
 * > *"some people are slower, some are faster and are waiting for it to move
 * > on."*
 *
 * A fast reader who has finished a stop and has no idea whether the next one is
 * in one second or nine has nothing to do but stare. That is the whole of the
 * "boring" failure, and it is not fixed by going faster — it is fixed by the
 * wait stopping being a surprise. So the ring fills over the stop, the seconds
 * remaining are printed inside it as a number, and the bar says how long the
 * rest of the tour will take. Three different granularities of the same fact,
 * because the reader is asking three different questions: *now?*, *soon?*, and
 * *is this worth watching at all?*
 *
 * The number inside the ring is not a reduced-motion fallback that appears
 * instead of the ring. It is always there. A ring alone is a shape you have to
 * estimate an angle from; a number alone gives no sense of a rate. Under
 * `prefers-reduced-motion` the ring stops sliding — `--dur` collapses to nothing
 * in `tokens.css` — and steps at the publish rate instead, which is the correct
 * degradation and needs no second component.
 *
 * ## Every control is live, including the ones that look redundant
 *
 * Back at the first stop is enabled, and re-shows the stop. Pause while already
 * paused is the resume. Next during travel jumps to the destination rather than
 * queueing. There is no state in which a button in this bar does nothing when
 * pressed, because a dead control in a bar that is driving the screen reads as
 * the app having hung — and this is the one moment in the product where the
 * user's model of cause and effect is already suspended.
 *
 * ## Skim
 *
 * After three stops the reader got ahead of, the bar offers to stop driving and
 * hand over the rest as a list. This is the honest answer to somebody faster
 * than the tour: the fastest version of a tour is not a faster tour, it is the
 * document. It is an offer and never automatic — deciding on somebody's behalf
 * that they would rather read than watch is the same mistake as deciding they
 * have finished a paragraph.
 */

import { PACE_CONTROL_ATTR } from './interruption'
import { PACES, paceSampleLabel, type PaceName, type ReadingSpeed } from './estimate'
import {
  aboutDuration,
  measuredSentence,
  offersSkim,
  positionLabel,
  progress,
  remainingMs,
  statusSentence,
  stopRemainingMs,
  type PacerState,
} from './pacer'
import './pace-controls.css'

export type PaceCommand = 'back' | 'toggle' | 'next' | 'stop' | 'skim'

interface TransportProps {
  state: PacerState
  onCommand(command: PaceCommand): void
}

/**
 * The ring's geometry.
 *
 * A 20px box with a 9px radius leaves a 1px gutter for the stroke's own width
 * without the circle clipping at the edges of its viewBox, which is what
 * happens when the radius is set to half the box and looks like a rendering
 * bug rather than a design.
 */
const RING_RADIUS = 9
const RING_LENGTH = 2 * Math.PI * RING_RADIUS

export function PaceTransport({ state, onCommand }: TransportProps) {
  const filled = progress(state)
  const stopLeft = stopRemainingMs(state)
  const paused = state.status === 'paused'
  const position = positionLabel(state)
  const left = remainingMs(state)

  return (
    <div className="pace-bar" {...{ [PACE_CONTROL_ATTR]: 'transport' }}>
      <div className="pace-row">
        <button
          type="button"
          className="pace-btn"
          onClick={() => onCommand('back')}
          title="Back — show the previous stop again"
          aria-label="Back"
        >
          <svg viewBox="0 0 20 20" aria-hidden="true">
            <path d="M12.5 4.5 7 10l5.5 5.5" />
          </svg>
        </button>

        <button
          type="button"
          className="pace-btn"
          onClick={() => onCommand('toggle')}
          title={paused ? 'Carry on (Space)' : 'Pause (Space)'}
          aria-label={paused ? 'Carry on' : 'Pause'}
        >
          {paused ? (
            <svg viewBox="0 0 20 20" aria-hidden="true">
              <path d="M6.5 4.5 15 10l-8.5 5.5Z" />
            </svg>
          ) : (
            <svg viewBox="0 0 20 20" aria-hidden="true">
              <path d="M7.5 5v10M12.5 5v10" />
            </svg>
          )}
        </button>

        {/*
          Next carries the ring, because the ring is a picture of when Next is
          about to happen on its own. Putting it anywhere else in the bar would
          leave the reader mapping a countdown onto a button by inference.
        */}
        <button
          type="button"
          className="pace-btn pace-next"
          onClick={() => onCommand('next')}
          title="Next stop"
          aria-label="Next stop"
        >
          <svg className="pace-ring" viewBox="0 0 20 20" aria-hidden="true">
            <circle className="pace-ring-track" cx="10" cy="10" r={RING_RADIUS} />
            <circle
              className="pace-ring-fill"
              cx="10"
              cy="10"
              r={RING_RADIUS}
              style={{
                strokeDasharray: RING_LENGTH,
                strokeDashoffset: RING_LENGTH * (1 - filled),
              }}
            />
          </svg>
          <span className="pace-count">{stopLeft === null ? '→' : Math.ceil(stopLeft / 1000)}</span>
        </button>

        <span className="pace-spacer" />

        <button
          type="button"
          className="pace-btn pace-quiet"
          onClick={() => onCommand('stop')}
          title="End the tour and stay where you are"
          aria-label="End the tour"
        >
          <svg viewBox="0 0 20 20" aria-hidden="true">
            <path d="M5.5 5.5h9v9h-9Z" />
          </svg>
        </button>
      </div>

      <p className="pace-line">
        {position === '' ? null : <span className="pace-pos">{position}</span>}
        <span className="pace-status">{statusSentence(state)}</span>
      </p>

      {offersSkim(state) ? (
        <div className="pace-skim">
          {/*
            The time goes in the sentence and not in the button. "Skim the
            remaining about 40 sec" was what a phrase built by concatenation
            reads like once it is on screen — the vagueness `aboutDuration` is
            written for makes a fine sentence and an ungrammatical label.
          */}
          <p>You’re ahead of it — {aboutDuration(left)} of tour left.</p>
          <button type="button" className="pace-skim-btn" onClick={() => onCommand('skim')}>
            Show the rest as a list
          </button>
        </div>
      ) : null}
    </div>
  )
}

interface SpeedProps {
  speed: ReadingSpeed
  onPick(pace: PaceName): void
  /** Clears the learned correction. The choice is kept. */
  onForget(): void
}

/**
 * The reading-speed preference.
 *
 * Every option says how long a real paragraph gets at that pace, and the number
 * is computed by `estimate.ts` from `SAMPLE_PARAGRAPH` rather than written into
 * the label. A hand-written "about 12 seconds" would be a printed copy of a
 * fact, and this repository has been bitten by those repeatedly — `tokens.test.ts`
 * opens with three of them. Deriving it means the label cannot survive a change
 * to the model that makes it false.
 *
 * The learned correction gets one sentence and a Reset, and is deliberately not
 * a control. There is nothing sensible for a person to type into it; what they
 * are owed is to be able to see it and to be able to throw it away.
 */
export function ReadingSpeedControl({ speed, onPick, onForget }: SpeedProps) {
  return (
    <div className="pace-speed" {...{ [PACE_CONTROL_ATTR]: 'speed' }}>
      <fieldset className="pace-speed-set">
        <legend className="pace-speed-legend">Reading pace</legend>
        {PACES.map((pace) => (
          <label key={pace.name} className={`pace-opt${speed.pace === pace.name ? ' on' : ''}`}>
            <input
              type="radio"
              name="pace"
              value={pace.name}
              checked={speed.pace === pace.name}
              onChange={() => onPick(pace.name)}
            />
            <span className="pace-opt-label">{pace.label}</span>
            <span className="pace-opt-help">a paragraph gets {paceSampleLabel(pace.name)}</span>
          </label>
        ))}
      </fieldset>
      <p className="pace-learned">
        <span>{measuredSentence(speed)}</span>
        {speed.scale === 1 ? null : (
          <button type="button" className="pace-reset" onClick={onForget}>
            Reset
          </button>
        )}
      </p>
    </div>
  )
}
