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
  const [sending, setSending] = useState(false)

  const blocked = agent.target === null

  /*
   * Awaited, since a target can be on another computer.
   *
   * A send to this machine is a write into a pty and answers on the same tick; a
   * send to a paired machine is a round trip that the far end can refuse. So the
   * field is cleared and the button says "Sent" only once the answer is in, and
   * the press is held closed in between — a second press mid-flight would put
   * the same line on the wire twice, and the first one to come back would clear
   * a field that had already been retyped.
   *
   * A refusal leaves what was typed exactly where it is. There is no worse
   * moment to lose somebody's sentence than the moment they have been told it
   * did not arrive.
   */
  const send = (): void => {
    if (blocked || sending) return
    setSending(true)
    void agent
      .send(compose(instruction))
      .then((landed) => {
        if (!landed) return
        setInstruction('')
        setSent(true)
        onSent?.()
      })
      .finally(() => setSending(false))
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
        disabled={blocked || sending}
        // The reason, on the control that is refusing. A greyed button with no
        // explanation is what this whole change is against.
        title={blocked ? agent.reason : `Send to ${agent.target?.label ?? ''}`}
        onClick={send}
      >
        {sending ? 'Sending…' : sent ? 'Sent' : action}
      </button>

      {/*
        One line under the field, and only ever one of the two.

        `agent.reason` is about the *choice* and is known before anything is
        pressed; `agent.problem` is the far machine's own words about an attempt
        that failed. A blocked picker cannot have attempted anything, so they
        cannot both be true — but they are written as one element rather than two
        so that a future case where they could be does not stack two sentences
        under a 26rem popup.
      */}
      {(blocked || agent.problem !== '') && (
        <p className="bw-send-reason" role="status">
          {blocked ? agent.reason : agent.problem}
        </p>
      )}
    </div>
  )
}
