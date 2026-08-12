import { useCallback, useEffect, useRef, useState } from 'react'
import { AttachChips } from '../chat/attach/AttachChips'
import { AttachMenu } from '../chat/attach/AttachMenu'
import {
  addAttachment,
  composeMessage,
  removeAttachment,
  REJECTION_TEXT,
  terminalPayload,
  type Attachment,
} from '../chat/attach/mentions'
import { appendSpoken } from '../chat/voice/dictation'
import { DictateButton } from '../chat/voice/DictateButton'
import './ChatComposer.css'

interface Props {
  /** Absent while no session is focused; the box then explains itself. */
  onSend?: (text: string) => void
  /** Project root. Attachments are resolved and confined to it. */
  cwd?: string | null
  disabled?: boolean
  placeholder?: string
}

const MAX_ROWS = 12
/** How long a refusal stays on screen before the chips row gets quiet again. */
const NOTICE_MS = 4000

/**
 * Typing into chat mode.
 *
 * The message is written to the session's terminal exactly as if it had been
 * typed there, because that IS where the agent is listening — chat mode is a
 * different view of the same session, not a different channel. So there is no
 * second transport to keep in sync, and a reply sent here shows up in the
 * terminal view too.
 *
 * That one channel is also why attachments are text: an attachment is an
 * `@"…"` mention the CLI expands on submit, not an upload. `chat/attach/
 * mentions.ts` holds the exact forms and the measurements behind them —
 * including the reason a message carrying one is sent with a trailing space.
 *
 * `onSend` is handed the message *without* its carriage return, and the caller
 * must not simply append one: measured through a pty, a single write of 64
 * bytes or more is read as pasted text and its Enter does not submit, so
 * `writeToSession(id, text + '\r')` silently does nothing for every message
 * carrying an attachment. `terminalWrites` in `mentions.ts` is the sequence
 * that works — two writes, `SUBMIT_GAP_MS` apart.
 */
export function ChatComposer({ onSend, cwd, disabled = false, placeholder }: Props) {
  const [text, setText] = useState('')
  const [attachments, setAttachments] = useState<Attachment[]>([])
  const [notice, setNotice] = useState<string | null>(null)
  const boxRef = useRef<HTMLTextAreaElement>(null)

  const root = cwd ?? ''

  // Grow with the content up to a ceiling, then scroll. Measured from
  // scrollHeight rather than counting newlines, which ignores wrapped lines.
  useEffect(() => {
    const box = boxRef.current
    if (!box) return
    box.style.height = 'auto'
    const line = parseFloat(getComputedStyle(box).lineHeight) || 18
    box.style.height = `${Math.min(box.scrollHeight, line * MAX_ROWS)}px`
  }, [text])

  // A refusal is transient information, so it clears itself rather than
  // needing a dismiss button next to the thing it is complaining about.
  useEffect(() => {
    if (notice === null) return
    const timer = setTimeout(() => setNotice(null), NOTICE_MS)
    return () => clearTimeout(timer)
  }, [notice])

  // Attachments belong to the message being written, not to the session: when
  // the project changes underneath, the paths they point at no longer apply.
  useEffect(() => {
    setAttachments([])
    setNotice(null)
  }, [root])

  const focusBox = useCallback(() => boxRef.current?.focus(), [])

  const send = useCallback(() => {
    const message = composeMessage(attachments, text)
    if (message === '' || disabled || !onSend) return
    onSend(terminalPayload(message))
    setText('')
    setAttachments([])
  }, [attachments, text, disabled, onSend])

  const onKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>): void => {
    // Enter sends, Shift+Enter is a newline — the convention every chat app
    // uses, and the opposite would make multi-line prompts painful.
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault()
      send()
    }
  }

  const add = useCallback(
    (relPath: string, isDirectory: boolean) => {
      const result = addAttachment(attachments, root, `${root}/${relPath}`, isDirectory)
      if (result.ok) {
        setAttachments(result.attachments)
        setNotice(null)
      } else {
        setNotice(REJECTION_TEXT[result.reason])
      }
    },
    [attachments, root],
  )

  const insert = useCallback((snippet: string) => {
    setText((current) => appendSpoken(current, snippet))
  }, [])

  const idle = !onSend
  const off = disabled || idle
  const empty = composeMessage(attachments, text) === ''

  return (
    <div className="chat-composer">
      <AttachChips
        attachments={attachments}
        notice={notice}
        onRemove={(path) => setAttachments((current) => removeAttachment(current, path))}
      />
      <div className="cc-row">
        <AttachMenu
          root={root}
          attachments={attachments}
          onAdd={add}
          onInsert={insert}
          onClose={focusBox}
          disabled={off || root === ''}
        />
        <textarea
          ref={boxRef}
          className="cc-input"
          rows={1}
          value={text}
          disabled={off}
          spellCheck
          placeholder={
            idle ? 'Open a session to write to it' : (placeholder ?? 'Message the agent…  (Enter to send, Shift+Enter for a new line)')
          }
          aria-label="Message the agent"
          onChange={(event) => setText(event.target.value)}
          onKeyDown={onKeyDown}
        />
        <DictateButton onFocusComposer={focusBox} disabled={off} />
        <button
          type="button"
          className="cc-send"
          onClick={send}
          disabled={off || empty}
          aria-label="Send"
          title="Send (Enter)"
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor">
            <path d="M4 12h15M13 6l6 6-6 6" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
      </div>
    </div>
  )
}
