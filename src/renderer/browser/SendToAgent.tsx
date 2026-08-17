import { useState } from 'react'
import type { AgentTarget } from './useAgentTarget'

interface Props {
  agent: AgentTarget
  /** Turn what was typed into the one line the agent receives. */
  compose(instruction: string): string
  placeholder: string
  /** The word on the button before anything has been sent. */
  action: string
  /** Called once a send actually happened, so a popup can close itself. */
  onSent?: () => void
}

/**
 * A session picker, a line to type, and a Send that is off until a session is
 * chosen.
 *
 * One component for all three senders — an inspected element, a recorded flow,
 * a screenshot — because they differ only in what they compose. Three copies is
 * how one of them ends up still sending to whatever was focused.
 *
 * The picker is a plain `<select>`. That is not laziness: it is the control the
 * platform already draws as a menu, it is keyboard-reachable without any work,
 * and it renders correctly *over a native browser view* — which the app's own
 * portalled menus cannot do, because a `WebContentsView` composites above the
 * entire renderer. `overlay-watch.ts` explains that at length. A native
 * `<select>`'s dropdown is drawn by the OS, above everything.
 *
 * "Sent" is a state on the button rather than a toast, and it is cleared the
 * moment the field is touched again — a button that says Sent about a line
 * nobody has sent is the same lie as one that says nothing at all.
 */
export function SendToAgent({ agent, compose, placeholder, action, onSent }: Props) {
  const [instruction, setInstruction] = useState('')
  const [sent, setSent] = useState(false)

  const blocked = agent.target === null

  const send = (): void => {
    if (blocked) return
    if (!agent.send(compose(instruction))) return
    setInstruction('')
    setSent(true)
    onSent?.()
  }

  return (
    <div className="bw-send">
      <label className="bw-send-target">
        <span className="bw-send-target-word">To</span>
        <select
          className="bw-session-picker"
          value={agent.chosenId}
          aria-label="Session to send to"
          disabled={agent.unavailable || agent.sessions.length === 0}
          onChange={(event) => agent.choose(event.target.value)}
        >
          {/*
            An empty first option, always present and never removed once a
            choice is made. It is the only way back to "nothing chosen", and
            "nothing chosen" is the state this picker exists to make possible.
          */}
          <option value="">Choose a session…</option>
          {agent.sessions.map((session) => (
            <option key={session.id} value={session.id} disabled={session.ended}>
              {session.ended ? `${session.label} (exited)` : session.label}
            </option>
          ))}
        </select>
      </label>

      <input
        className="bw-instruction"
        type="text"
        value={instruction}
        placeholder={placeholder}
        aria-label="Message for the agent"
        onChange={(event) => {
          setInstruction(event.target.value)
          setSent(false)
        }}
        onKeyDown={(event) => {
          if (event.key !== 'Enter') return
          event.preventDefault()
          send()
        }}
      />

      <button
        type="button"
        className="bw-primary"
        disabled={blocked}
        // The reason, on the control that is refusing. A greyed button with no
        // explanation is what this whole change is against.
        title={blocked ? agent.reason : `Send to ${agent.target?.label ?? ''}`}
        onClick={send}
      >
        {sent ? 'Sent' : action}
      </button>

      {blocked && (
        <p className="bw-send-reason" role="status">
          {agent.reason}
        </p>
      )}
    </div>
  )
}
