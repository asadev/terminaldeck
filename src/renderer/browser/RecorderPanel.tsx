import { oneLine } from './capture-text'
import { SendToAgent } from './SendToAgent'
import type { RecordedStep, RecordingState } from './bridge'
import type { AgentTarget } from './useAgentTarget'

interface Props {
  state: RecordingState
  /** The session this browser window sends to — chosen, never guessed. */
  agent: AgentTarget
  onStop(): void
  onClear(): void
  onCopy(): void
  copied: boolean
}

/** One word per kind, so the eye can scan the left edge of the list. */
function kindLabel(kind: RecordedStep['kind']): string {
  switch (kind) {
    case 'navigate':
      return 'Go'
    case 'click':
      return 'Click'
    case 'type':
      return 'Type'
    case 'select':
      return 'Choose'
    case 'check':
      return 'Check'
    case 'press':
      return 'Press'
    case 'submit':
      return 'Submit'
  }
}

function stepDetail(step: RecordedStep): string {
  if (step.kind === 'navigate') return step.url
  if (step.kind === 'type') return step.redacted ? 'the password' : `"${step.value}"`
  if (step.kind === 'select') return step.redacted ? 'a value' : `"${step.value}"`
  if (step.kind === 'press') return step.key
  if (step.kind === 'check') return step.checked ? 'on' : 'off'
  return step.label ? `"${step.label}"` : ''
}

/**
 * The recorded flow.
 *
 * Two things this panel refuses to do quietly. It never shows a password, even
 * as asterisks in a field it could have captured — the value never left the
 * page, and a row of dots would suggest it did. And while recording is on, the
 * panel says so at the top in a way that does not scroll away, because the
 * other indicator is inside the page and the page is what you are looking at.
 */
export function RecorderPanel({ state, agent, onStop, onClear, onCopy, copied }: Props) {
  const empty = state.steps.length === 0

  return (
    <div className="bw-panel">
      {/*
        No "Flow" badge and no step count here.

        The strip above this already reads `Flow (8)` — it is the only thing left
        in what used to be a two-tab bar — so a badge saying Flow and a line
        saying "8 steps" underneath it was the same fact three times in two
        centimetres. What is left is the one thing the heading cannot say: that
        recording is live, or that there is nothing in the list yet and why.
      */}
      <div className="bw-panel-head">
        {state.recording && (
          <span className="bw-recording" role="status">
            <span className="bw-recording-dot" aria-hidden="true" />
            Recording
          </span>
        )}
        {empty && (
          <span className="bw-muted">
            {state.recording
              ? 'Use the page — every click, entry and navigation lands here.'
              : 'Nothing recorded yet.'}
          </span>
        )}
        {state.truncated && <span className="bw-warn">stopped at the step limit</span>}
        <span className="bw-spacer" />
        {state.recording && (
          <button type="button" className="bw-text-button" onClick={onStop}>
            Stop
          </button>
        )}
        <button type="button" className="bw-text-button" disabled={empty} onClick={onCopy}>
          {copied ? 'Copied' : 'Copy'}
        </button>
        <button type="button" className="bw-text-button" disabled={empty} onClick={onClear}>
          Clear
        </button>
      </div>

      {!empty && (
        <ol className="bw-steps">
          {state.steps.map((step, index) => (
            <li key={`${step.at}-${index}`}>
              <span className="bw-step-kind">{kindLabel(step.kind)}</span>
              <span className="bw-step-detail">{stepDetail(step)}</span>
              {step.selector && (
                <code className="bw-step-selector" title={step.selector}>
                  {step.selector}
                </code>
              )}
            </li>
          ))}
        </ol>
      )}

      {/*
        The same picker the element popup uses, over the same per-window choice.
        A flow that went to whichever session happened to be focused is the exact
        complaint the picker exists for, and having two senders disagree about
        where "the agent" is would be worse than either.

        Nothing to send is a different state from nowhere to send it, so the row
        goes when the list is empty rather than offering a disabled button under
        a picker that would work.
      */}
      {!empty && (
        <SendToAgent
          agent={agent}
          compose={(instruction) => {
            const lead = oneLine(instruction)
            return lead ? `${lead} ${state.line}` : state.line
          }}
          placeholder="Anything to say about this flow?"
          action="Send flow"
        />
      )}
    </div>
  )
}
