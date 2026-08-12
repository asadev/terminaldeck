import { useCallback, useEffect, useRef, useState } from 'react'
import './ChatComposer.css'

interface Props {
  /** Absent while no session is focused; the box then explains itself. */
  onSend?: (text: string) => void
  disabled?: boolean
  placeholder?: string
}

const MAX_ROWS = 12

/**
 * Typing into chat mode.
 *
 * The message is written to the session's terminal exactly as if it had been
 * typed there, because that IS where the agent is listening — chat mode is a
 * different view of the same session, not a different channel. So there is no
 * second transport to keep in sync, and a reply sent here shows up in the
 * terminal view too.
 */
export function ChatComposer({ onSend, disabled = false, placeholder }: Props) {
  const [text, setText] = useState('')
  const boxRef = useRef<HTMLTextAreaElement>(null)

  // Grow with the content up to a ceiling, then scroll. Measured from
  // scrollHeight rather than counting newlines, which ignores wrapped lines.
  useEffect(() => {
    const box = boxRef.current
    if (!box) return
    box.style.height = 'auto'
    const line = parseFloat(getComputedStyle(box).lineHeight) || 18
    box.style.height = `${Math.min(box.scrollHeight, line * MAX_ROWS)}px`
  }, [text])

  const send = useCallback(() => {
    const value = text.trim()
    if (!value || disabled || !onSend) return
    onSend(value)
    setText('')
  }, [text, disabled, onSend])

  const onKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>): void => {
    // Enter sends, Shift+Enter is a newline — the convention every chat app
    // uses, and the opposite would make multi-line prompts painful.
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      send()
    }
  }

  const idle = !onSend

  return (
    <div className="chat-composer">
      <textarea
        ref={boxRef}
        className="cc-input"
        rows={1}
        value={text}
        disabled={disabled || idle}
        spellCheck
        placeholder={
          idle ? 'Open a session to write to it' : (placeholder ?? 'Message the agent…  (Enter to send, Shift+Enter for a new line)')
        }
        aria-label="Message the agent"
        onChange={(event) => setText(event.target.value)}
        onKeyDown={onKeyDown}
      />
      <button
        type="button"
        className="cc-send"
        onClick={send}
        disabled={disabled || idle || text.trim() === ''}
        aria-label="Send"
        title="Send (Enter)"
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor">
          <path d="M4 12h15M13 6l6 6-6 6" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>
    </div>
  )
}
