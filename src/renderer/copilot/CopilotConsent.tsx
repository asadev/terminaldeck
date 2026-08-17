import { useEffect, useState } from 'react'
import { Modal } from '../components/Modal'
import {
  argRows,
  secondsLeft,
  timeoutSentence,
  toolHeading,
  type ConsentRequestView,
} from './consent-model'
import './copilot.css'

/**
 * The confirmation the alter tier blocks on.
 *
 * Four questions, answered on one screen, because a permission prompt that
 * leaves any of them out is one people clear by reflex:
 *
 *   **What** — the tool's own title, and the sentence the tool wrote about
 *   *these* arguments. That sentence is built in the main process by the tool
 *   itself and is the same string the action log records, so what somebody
 *   approves and what the log says they approved cannot differ.
 *
 *   **Who** — the copilot. Said in words rather than assumed from the fact that
 *   a dialog appeared: this app also opens dialogs on your own behalf, and the
 *   one difference that matters about this one is that nobody in this window
 *   asked for it.
 *
 *   **With what arguments** — every one, verbatim, already scrubbed on the far
 *   side. Not summarised, not hidden behind a disclosure. A dialog that says
 *   "change 2 settings" is asking somebody to approve a number.
 *
 *   **What happens if you say nothing** — it is refused, in so many seconds,
 *   counting down in front of them. This is the one that is usually left out and
 *   it is the most important: walking away from this dialog is not deferring the
 *   decision, it is making it.
 *
 * ## Everything that is not "Allow" is a refusal, on purpose
 *
 * Escape, the scrim, the ✕ and the Refuse button all answer no. That is not
 * four ways to cancel — it is one rule, that the only path to `granted: true`
 * is somebody pressing the one button that says so. `consent.ts` holds the same
 * rule on the far side, and this dialog would be lying about the gate if it
 * offered any gesture that left the question open.
 *
 * There is deliberately no "always allow". It is a real feature with real
 * storage and its own audit rows, and adding it here as a convenience is how a
 * gate quietly becomes a formality — `consent.ts` sets out at length what it
 * would have to be instead.
 *
 * ## An unattended routine never reaches this
 *
 * A routine firing at 03:00 runs through the copilot with nobody near the
 * machine, and `control.ts` refuses its alter-tier calls at the boundary with
 * `not-permitted-unattended` before the broker is ever asked. So this component
 * cannot be drawn for a question nobody can answer — which matters, because a
 * dialog that appears and times out at four in the morning trains a person to
 * dismiss dialogs.
 */

interface Props {
  /** The oldest outstanding question, or null when there is none. */
  question: ConsentRequestView | null
  /** How many more are behind it. `consent.ts` caps the total at three. */
  waiting?: number
  /**
   * Tool id → the title the catalogue gives it, from `deck-control:status`.
   *
   * Optional, and the dialog falls back to the dotted id. A heading that is a
   * tool id is poor; a heading that is *wrong* would be unforgivable, and the
   * id is never wrong.
   */
  titles?: Readonly<Record<string, string>>
  onAnswer(id: string, approved: boolean): void
}

/** How often the countdown re-renders. One second, because it counts seconds. */
const TICK_MS = 1000

export function CopilotConsent({ question, waiting = 0, titles = {}, onAnswer }: Props) {
  /*
   * The clock the countdown is read against.
   *
   * State rather than a `Date.now()` in the render, because a render is not a
   * clock: without something to schedule the next one, the number would freeze
   * at whatever it was when the dialog opened and quietly claim there is still
   * a minute left when there are three seconds. The interval runs only while a
   * question is on screen.
   */
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!question) return
    setNow(Date.now())
    const timer = setInterval(() => setNow(Date.now()), TICK_MS)
    return () => clearInterval(timer)
  }, [question])

  if (!question) return null

  const seconds = secondsLeft(question, now)
  const rows = argRows(question.args)

  return (
    <Modal
      open
      size="lg"
      title={toolHeading(question.tool, titles)}
      description="The copilot is asking to do this. It will not happen unless you allow it."
      // Every dismissal is a refusal. See the header — this is the rule, not a
      // shortcut, and the far side holds the same one.
      onClose={() => onAnswer(question.id, false)}
      footer={
        <>
          <button
            type="button"
            className="modal-btn"
            onClick={() => onAnswer(question.id, false)}
            // Focused on open so the keyboard's first Return refuses. The panel
            // itself takes focus first (see `Modal`), so this only decides where
            // Tab lands and what a hurried Return does — and a hurried Return
            // must not approve.
            autoFocus
          >
            Refuse
          </button>
          <button
            type="button"
            className="modal-btn primary"
            onClick={() => onAnswer(question.id, true)}
          >
            Allow once
          </button>
        </>
      }
    >
      <div className="cc-body">
        <p className="cc-summary">{question.summary}</p>

        {rows.length > 0 && (
          <dl className="cc-args">
            {rows.map((row) => (
              <div className="cc-arg" key={row.name}>
                <dt>{row.name}</dt>
                {/* The value is agent-authored text — a session title, a line
                    it wants typed, a settings value. It goes in as a text node
                    and never through a parser: this app does not hand agent
                    output to `innerHTML`, least of all inside the dialog that
                    exists to be trusted. */}
                <dd>{row.value}</dd>
              </div>
            ))}
          </dl>
        )}

        <p className="cc-tool">
          <span className="cc-tier">{question.tier}</span>
          <span className="cc-tool-id">{question.tool}</span>
        </p>

        {/* The fourth question, and the one nothing else on screen answers.
            `data-urgent` turns it critical in the last ten seconds rather than
            leaving a number to be noticed. */}
        <p className="cc-timeout" data-urgent={seconds <= 10 ? 'true' : undefined}>
          {timeoutSentence(seconds)}
        </p>

        {waiting > 0 && (
          <p className="cc-waiting">
            {waiting === 1
              ? 'One more question is waiting behind this one.'
              : `${waiting} more questions are waiting behind this one.`}
          </p>
        )}
      </div>
    </Modal>
  )
}
