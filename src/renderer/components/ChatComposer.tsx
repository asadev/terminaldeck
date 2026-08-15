import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react'
import { AttachChips } from '../chat/attach/AttachChips'
import { AttachMenu } from '../chat/attach/AttachMenu'
import {
  addAttachment,
  composeMessage,
  removeAttachment,
  REJECTION_TEXT,
  shellQuote,
  terminalPayload,
  type Attachment,
} from '../chat/attach/mentions'
import { appendSpoken } from '../chat/voice/dictation'
import { DictateButton } from '../chat/voice/DictateButton'
import { useControlOffer } from '../features/offer'
import './ChatComposer.css'

interface Props {
  /** Absent while no session is focused; the box then explains itself. */
  onSend?: (text: string) => void
  /** Project root. Attachments are resolved and confined to it. */
  cwd?: string | null
  disabled?: boolean
  placeholder?: string
  /**
   * The agent's controls, rendered on the box's own bottom row beside the plus.
   *
   * A slot rather than an import, because `wiring.test.ts` pins `AgentControls`
   * and `UsageStrip` to `ChatView.tsx` — that table is the record of them
   * having shipped mounted nowhere, and the fix for a messy composer is not to
   * move the seam it guards. So the owner stays the same and only the place
   * they are drawn changes.
   */
  controls?: ReactNode
  /**
   * Whether this session is a plain shell rather than an agent CLI.
   *
   * It decides what the menu behind the plus *offers*, not whether there is
   * one. That distinction is the bug this prop was born with. Every entry
   * behind the plus used to add an `@"path"` mention, which an agent expands on
   * submit and a shell types verbatim at its prompt — so the menu was withdrawn
   * from a shell entirely, and that composer was left with a microphone, a send
   * button and nothing else. Reported back in one sentence: *"you actually
   * removed everything rather than making it simple"*.
   *
   * Picking a file out of the project is not an agent feature; only the form of
   * the result was. So a shell keeps the menu and gets the form its prompt can
   * read — a quoted absolute path typed into the command line — and loses only
   * the two rows that genuinely need an agent on the other end: an image, which
   * is a separate kind of thing only because an agent *sees* it, and
   * connectors, which are its tools.
   */
  shell?: boolean
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
 *
 * ## The shape
 *
 * One box, tall enough to look like somewhere you write a paragraph, with every
 * control inside its frame: attachments above the text, and a single row under
 * it holding the plus, the agent's controls, the microphone and send. Before
 * this, the plus and the microphone squeezed a single-line field between them
 * and three further rows of controls and readouts hung underneath — which is
 * the thing that got reported, in these words: "it's very messy with a lot of
 * options under the chat box".
 *
 * Nothing on that row is a bare icon on its own: the plus carries a word ("Add"
 * for an agent, "Path" for a shell), the controls carry their names and their
 * values, the panel behind them is called Options and names its whole contents
 * on hover, and the two glyphs that stay glyphs — the microphone and send — are
 * the pair every chat app in the world draws in that corner, and both say what
 * they are on hover.
 *
 * ## Folding is not deleting
 *
 * Said here because it is the mistake this composer has already made once. The
 * first pass at "one box with the options folded inside it" folded two controls
 * onto the row, two behind a button labelled "More", and — on a shell — the plus
 * into nothing at all, which came back as *"all the options you have actually
 * removed"*. Nothing on this row may be dropped to make the row shorter. If a
 * control does not fit, it goes in the Options panel, which lists every one of
 * them; if it does not belong on this kind of session, it changes form rather
 * than disappearing. `wiring.test.ts` pins the list.
 */
export function ChatComposer({
  onSend,
  cwd,
  disabled = false,
  placeholder,
  controls,
  shell = false,
}: Props) {
  const [text, setText] = useState('')
  const [attachments, setAttachments] = useState<Attachment[]>([])
  const [notice, setNotice] = useState<string | null>(null)
  const boxRef = useRef<HTMLTextAreaElement>(null)
  /**
   * What the microphone's place says when voice dictation is not installed.
   *
   * Null while it is on, and then the real button is drawn. Uninstalling used
   * to leave nothing at all here — half the store's features disappearing
   * without a trace is the failure FEATURE-STORE.md is most worried about, and
   * a corner of a chat box is exactly where somebody looks for a microphone and
   * concludes the app has none.
   */
  const voiceOffer = useControlOffer('chat.dictate')

  const root = cwd ?? ''

  // Grow with the content up to a ceiling, then scroll. Measured from
  // scrollHeight rather than counting newlines, which ignores wrapped lines.
  // The floor is CSS's, not this function's: `min-height` on `.cc-input` clamps
  // whatever is written here, so an empty box still stands three lines tall.
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

  const insert = useCallback((snippet: string) => {
    setText((current) => appendSpoken(current, snippet))
  }, [])

  /**
   * What a pick in the menu becomes.
   *
   * Two answers, because there are two things on the other end of this box. An
   * agent gets an attachment, which is an `@"path"` mention the CLI expands on
   * submit and a chip above the text in the meantime. A shell gets the path
   * itself, quoted, appended to the command line it is already writing — there
   * is nothing to attach to a `/bin/zsh`, and `shellQuote` is what keeps a
   * folder called "My Project" from arriving as two arguments.
   */
  const add = useCallback(
    (relPath: string, isDirectory: boolean) => {
      const target = `${root}/${relPath}`
      if (shell) {
        insert(shellQuote(target))
        return
      }
      const result = addAttachment(attachments, root, target, isDirectory)
      if (result.ok) {
        setAttachments(result.attachments)
        setNotice(null)
      } else {
        setNotice(REJECTION_TEXT[result.reason])
      }
    },
    [attachments, root, shell, insert],
  )

  /**
   * The padding is part of the field.
   *
   * A big box with a small textarea inside it is a trap: click in the margin
   * above the controls and nothing happens, which reads as a dead surface. Only
   * a press that landed on the box itself counts — a press that started on a
   * button, a chip or the text is that thing's own — and the default is
   * prevented so focus does not move away again on mouse-up.
   */
  const focusFromFrame = (event: React.MouseEvent<HTMLDivElement>): void => {
    if (event.target !== event.currentTarget) return
    event.preventDefault()
    focusBox()
  }

  const idle = !onSend
  const off = disabled || idle
  const empty = composeMessage(attachments, text) === ''

  return (
    <div className="chat-composer">
      <div className={off ? 'cc-box cc-box-off' : 'cc-box'} onMouseDown={focusFromFrame}>
        <AttachChips
          attachments={attachments}
          notice={notice}
          onRemove={(path) => setAttachments((current) => removeAttachment(current, path))}
        />

        <textarea
          ref={boxRef}
          className="cc-input"
          rows={1}
          value={text}
          disabled={off}
          spellCheck
          placeholder={idle ? 'Open a session to write to it' : (placeholder ?? 'Message the agent…')}
          // The label follows the placeholder rather than being fixed: a screen
          // reader on a plain shell was being told it had focused a box for
          // messaging an agent that is not in the session. The ellipsis is a
          // typographic invitation and belongs only to the visible hint.
          aria-label={(placeholder ?? 'Message the agent').replace(/…$/, '')}
          onChange={(event) => setText(event.target.value)}
          onKeyDown={onKeyDown}
        />

        <div className="cc-foot">
          <div className="cc-foot-left">
            {/* Drawn for a shell as well as for an agent, and the mode is what
                differs — see the `shell` prop for the regression that rule
                exists to close. */}
            <AttachMenu
              root={root}
              attachments={attachments}
              onAdd={add}
              onInsert={insert}
              onClose={focusBox}
              disabled={off || root === ''}
              mode={shell ? 'path' : 'mention'}
            />
            {controls}
          </div>
          <div className="cc-foot-right">
            {/* The microphone belongs to voice dictation, which can be
                uninstalled — and where it would have been, it offers itself
                back. It used to simply vanish, which teaches the reader that
                this app cannot dictate. Pressing the offer installs the feature
                and the real microphone is under the pointer a frame later. */}
            {voiceOffer === null ? (
              <DictateButton onFocusComposer={focusBox} disabled={off} />
            ) : (
              <button
                type="button"
                className="cc-tool"
                data-offer
                aria-label={voiceOffer.title}
                title={voiceOffer.title}
                onClick={voiceOffer.accept}
              >
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
                  <rect x="9" y="3" width="6" height="11" rx="3" strokeWidth="1.7" />
                  <path d="M5 11a7 7 0 0 0 14 0M12 18v3" strokeWidth="1.7" strokeLinecap="round" />
                </svg>
              </button>
            )}
            <button
              type="button"
              className="cc-send"
              onClick={send}
              disabled={off || empty}
              aria-label="Send"
              title="Send — Enter sends, Shift+Enter starts a new line"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
                <path d="M4 12h15M13 6l6 6-6 6" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
