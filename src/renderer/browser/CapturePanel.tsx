import { useState } from 'react'
import type { BrowserCapture, LabelSource } from './bridge'

interface Props {
  capture: BrowserCapture
  /** Absent when no session is focused — the send button says so rather than lying. */
  onSend: ((text: string) => void) | undefined
  onClear(): void
}

/** How the panel names where the label came from. */
export function describeLabelSource(source: LabelSource): string {
  return source === 'text' ? 'text' : source === 'none' ? '' : source
}

/**
 * Flatten anything on its way to the agent.
 *
 * Pawl types this into a PTY running a coding CLI, where a newline submits the
 * prompt — a two-line message would send the first line as the whole
 * instruction. The main process already guarantees this for the context half;
 * this covers what the user typed into the instruction field.
 */
export function oneLine(value: string): string {
  let out = ''
  for (const char of value) {
    const code = char.codePointAt(0) ?? 0
    // C0 and C1 controls plus the Unicode line separators, written as numbers
    // rather than a regex escape so the intent survives a copy-paste: a newline
    // in this string submits the agent's prompt early, and an ESC can repaint
    // the terminal it lands in.
    const control =
      code < 0x20 || (code >= 0x7f && code <= 0x9f) || code === 0x2028 || code === 0x2029
    out += control ? ' ' : char
  }
  return out.replace(/\s+/g, ' ').trim()
}

/** The exact string the agent receives. */
export function composeSend(context: string, instruction: string): string {
  const lead = oneLine(instruction)
  const tail = oneLine(context)
  return lead ? `${lead} ${tail}` : tail
}

/**
 * What was clicked while inspecting, and the one line about to be handed over.
 *
 * A footer rather than an overlay, for the same reason the device bar is a bar:
 * nothing in this React tree can paint on top of the native view.
 */
export function CapturePanel({ capture, onSend, onClear }: Props) {
  const [instruction, setInstruction] = useState('')
  const [sent, setSent] = useState(false)

  const send = (): void => {
    if (!onSend) return
    onSend(composeSend(capture.context, instruction))
    setInstruction('')
    setSent(true)
  }

  return (
    <div className="bw-panel">
      <div className="bw-panel-head">
        <span className="bw-badge">{capture.tag ? `<${capture.tag}>` : 'element'}</span>
        <code className="bw-selector" title={capture.selector}>
          {capture.selector}
        </code>
        <span className="bw-spacer" />
        <button type="button" className="bw-text-button" onClick={onClear}>
          Clear
        </button>
      </div>

      {capture.label && (
        <p className="bw-capture-label">
          <span className="bw-key">{describeLabelSource(capture.labelSource)}</span>
          {capture.label}
        </p>
      )}
      <p className="bw-capture-url">{capture.url}</p>

      <div className="bw-send">
        <input
          className="bw-instruction"
          type="text"
          value={instruction}
          placeholder="What should the agent do with it?"
          aria-label="Instruction for the agent"
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
          disabled={!onSend}
          title={onSend ? undefined : 'Open a session to send this to'}
          onClick={send}
        >
          {sent ? 'Sent' : 'Send to agent'}
        </button>
      </div>
    </div>
  )
}
