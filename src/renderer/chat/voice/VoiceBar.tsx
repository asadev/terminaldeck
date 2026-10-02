/**
 * The voice strip above the composer — the visible half of the conversation
 * loop.
 *
 * ## Why this is its own bar and not another button in the composer
 *
 * The composer's microphone is a *dictation* control: it fills the box and
 * stops, and it belongs beside the plus and the send arrow because it is one
 * more way of getting words into the same field. This is a different promise —
 * *"maybe it can pass commands to copilot and it will do the things and it will
 * interact with us"* — and while it is on, the app is doing something on its
 * own: holding the microphone open, sending without a press, and talking. A
 * mode that acts unprompted has to be visible for as long as it is on, which a
 * button in a row of buttons is not.
 *
 * ## What each state has to say, and why the wording matters
 *
 * Four states, and the person has to be able to tell them apart from across the
 * desk, because the wrong guess is either talking to a microphone that is shut
 * or staying quiet while it listens:
 *
 *  - **listening** — a live dot and the words as they are heard, so there is
 *    never a doubt about whether it caught something.
 *  - **thinking** — the turn went; the copilot has it. Nothing is being heard
 *    right now and the bar says so rather than leaving the dot pulsing.
 *  - **speaking** — with a Stop that actually stops mid-sentence, because a
 *    long answer read aloud is the one thing a person always wants to cut off.
 *  - **off** — one button, and what pressing it will do.
 */
import type { VoicePhase } from './useVoiceLoop'
import './VoiceBar.css'

interface Props {
  ready: boolean
  reason: string | null
  phase: VoicePhase
  heard: string
  problem: string | null
  handsFree: boolean
  onToggleHandsFree: () => void
  onStop: () => void
  onHush: () => void
}

export function VoiceBar({
  ready,
  reason,
  phase,
  heard,
  problem,
  handsFree,
  onToggleHandsFree,
  onStop,
  onHush,
}: Props) {
  // A machine with no free ear draws nothing at all. The composer's own
  // microphone (and the key behind it) is the answer there, and a second
  // control explaining that it cannot work is the thing this repository keeps
  // being audited for.
  if (!ready) return null

  const on = handsFree || phase !== 'off'

  return (
    <div className={`vb ${on ? 'vb-on' : ''}`} data-phase={phase}>
      <button
        type="button"
        className="vb-toggle"
        onClick={onToggleHandsFree}
        aria-pressed={handsFree}
        title={
          handsFree
            ? 'Stop the voice conversation'
            : 'Talk to the copilot — it listens, sends, and answers out loud'
        }
        data-testid="voice.handsfree"
      >
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <path d="M12 3a3 3 0 0 1 3 3v6a3 3 0 0 1-6 0V6a3 3 0 0 1 3-3Z" strokeWidth="1.8" />
          <path d="M5 11a7 7 0 0 0 14 0M12 18v3" strokeWidth="1.8" strokeLinecap="round" />
        </svg>
        <span>{handsFree ? 'Voice on' : 'Talk to it'}</span>
      </button>

      {phase === 'listening' && (
        <span className="vb-state vb-live">
          <i className="vb-dot" aria-hidden="true" />
          {heard ? <span className="vb-heard">{heard}</span> : <span className="vb-hint">Listening…</span>}
        </span>
      )}

      {phase === 'thinking' && <span className="vb-state vb-hint">Working on it…</span>}

      {phase === 'speaking' && (
        <span className="vb-state">
          <span className="vb-hint">Speaking…</span>
          <button type="button" className="vb-minor" onClick={onHush} data-testid="voice.hush">
            Stop
          </button>
        </span>
      )}

      {on && phase !== 'speaking' && (
        <button type="button" className="vb-minor vb-end" onClick={onStop} data-testid="voice.end">
          End
        </button>
      )}

      {/* A problem replaces the state rather than sitting under it: the bar is
          one line, and two lines of apology above a composer is the shape that
          pushes the box off a short window. */}
      {problem && <span className="vb-state vb-problem">{problem}</span>}
      {!problem && !on && reason && <span className="vb-state vb-hint">{reason}</span>}
    </div>
  )
}
