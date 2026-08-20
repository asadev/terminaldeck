import { useState } from 'react'
import { pathForSession } from '../session-transfer'
import type { AgentTarget } from './useAgentTarget'

interface Props {
  agent: AgentTarget
  /**
   * Turn what was typed into the one line the agent receives.
   *
   * `handed` is the path the *chosen session's own machine* knows the attached
   * file by, and it is empty for a sender with nothing attached. A composer must
   * use it rather than the path it started from: they are the same string only
   * when the session happens to be running on this computer, and the day they
   * differ is the day this whole change is about. See {@link Props.attach}.
   */
  compose(instruction: string, handed: string): string
  /**
   * A file on **this** machine that has to reach the chosen session with it.
   *
   * Optional, and most senders have none — an inspected element and a recorded
   * flow are text. A screenshot is not: it is a file in this computer's Pictures
   * folder, and a session on a paired PC cannot open a path in it. Asad,
   * 2026-08-20: *"it will send the path of my current PC instead of the server
   * where actually session is running… so session will not be able to see the
   * things that I have sent."*
   *
   * So it is handed over here, at the press, rather than composed into the
   * message by the popup — because only at the press is it known **which**
   * session was chosen, and the session is the only thing that decides whether
   * anything has to cross a wire at all. `session-transfer.ts` owns that
   * decision for every surface in the app; this is one of its callers.
   */
  attach?: { path: string }
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
export function SendToAgent({ agent, compose, attach, placeholder, action, onSent }: Props) {
  const [instruction, setInstruction] = useState('')
  const [sent, setSent] = useState(false)
  const [sending, setSending] = useState(false)
  /*
   * What went wrong getting the attached file to the session's machine.
   *
   * Its own state rather than `agent.problem`, which belongs to the *send* and
   * is cleared by it — a transfer that failed before any line was composed never
   * reaches that code at all. Both are drawn in the same single slot below, so
   * the popup still never shows two sentences.
   */
  const [trouble, setTrouble] = useState('')

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
    setTrouble('')
    /*
     * The file first, then the line — and never the other way round.
     *
     * A message naming a path the session cannot open is worse than no message:
     * the agent goes and looks, finds nothing, and reports a missing file to
     * somebody who is looking straight at it on their own screen. So if the
     * transfer refuses, nothing is sent and what was typed stays in the field.
     *
     * The button reads "Sending…" for the whole of it, which is also the only
     * thing on screen about a transfer that may take a moment. That is a state,
     * not a sentence about why a path is different from the one in the popup —
     * the standing rule this round is no explanatory prose, and the transfer is
     * meant to be invisible.
     */
    void (async (): Promise<void> => {
      let handed = ''
      if (attach) {
        // The row the picker is set to *now*, which is what decides whether
        // anything crosses a wire. Read at the press for the same reason
        // `useAgentTarget` re-resolves there: the gap between rendering an
        // enabled button and pressing it is where a choice changes.
        const outcome = await pathForSession(agent.target, { path: attach.path })
        if (!outcome.ok) {
          setTrouble(outcome.message)
          return
        }
        handed = outcome.path
      }
      const landed = await agent.send(compose(instruction, handed))
      if (!landed) return
      setInstruction('')
      setSent(true)
      onSent?.()
    })().finally(() => setSending(false))
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
          setTrouble('')
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
      {(blocked || trouble !== '' || agent.problem !== '') && (
        <p className="bw-send-reason" role="status">
          {blocked ? agent.reason : trouble !== '' ? trouble : agent.problem}
        </p>
      )}
    </div>
  )
}
